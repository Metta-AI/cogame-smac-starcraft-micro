# Build Docker. ONE image, TWO entrypoints: /bin/smac-starcraft-micro (the game
# server, which also runs the decision layer and the scripted enemy army) and
# /bin/smac-starcraft-micro-player (the thin seat registrar). The policy set is
# env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED), which
# is what keeps a champion and a scripted filler byte-identical apart from
# their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/smac
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/smac-nimcache \
  --out:smac-starcraft-micro \
  src/smac_starcraft_micro.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/smac-player-nimcache \
  --out:smac-starcraft-micro-player \
  src/smac_starcraft_micro_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/smac
COPY --from=build /workspace/smac/smac-starcraft-micro /bin/smac-starcraft-micro
COPY --from=build /workspace/smac/smac-starcraft-micro-player \
  /bin/smac-starcraft-micro-player
COPY --from=build /workspace/smac/*.json ./
COPY --from=build /workspace/smac/data ./data
COPY --from=build /workspace/smac/client ./client

CMD ["/bin/smac-starcraft-micro"]
