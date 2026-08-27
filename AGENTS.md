# AGENTS.md — working on cogame-smac-starcraft-micro

## What this repo is

A five-seat, fully cooperative micro-combat coworld, forked from
`Metta-AI/coworld-ctf` (paintbot). Five cogs — **one cog per unit** — fight
three seeded set-piece skirmishes against a scripted enemy army, and the only
thing that scores is how much of that army dies and how much of ours survives.

**The design note is authoritative**: `docs/plans/2026-08-27-smac-starcraft-micro-design.md`.
Read it before changing a rule. Every constant in `docs/RULES.md` is a config
field, so a rule change is usually a manifest change, not a code change.

## The three things you can break without noticing

1. **The determinism boundary.** The server records ONE `uint8` actuator mask
   per FRIENDLY unit per tick and one `gameHash` per tick. The wasm viewer
   re-steps the identical sim from those masks and compares the hash every
   tick. The whole enemy army — every spawn, every target choice, every swing —
   is **re-derived, never recorded**. Anything that makes the sim depend on
   something outside `(config, seed, recorded masks)` breaks every replay.

   Corollary: `src/smac/{units,enemy_ai,scenario}.nim` are **integer only**.
   `int` is 32 bits under `--cpu:wasm32`. `tests/test_enemy_ai.nim` greps them.

2. **Rune boundaries.** Every string that reaches the replay (`note`, `say`,
   policy labels, error text) is truncated on RUNE boundaries via
   `truncateRunes`. Slicing a `string` by byte index on any path to the replay
   is forbidden: a byte-truncated multi-byte character renders in a browser and
   then fails a strict UTF-8 parser.

3. **The two name spaces.** Prompts, seat frames, in-game labels and shouts
   carry only `RANGER-*`, `BLADE-*` and `E<n>`. Real policy names appear ONLY in
   the replay config JSON, `roster[].name`, the DOM scorebug/endcard and
   `results.names`. `tests/test_identity_privacy.nim` asserts BOTH halves.

## Where things live

| path | what |
|---|---|
| `src/smac/units.nim` | the role table and the damage ledger (pure, integer) |
| `src/smac/scenario.nim` | spawns, army bookkeeping, the sim guard, the end conditions, the wall-clock stop. `include`d into sim.nim |
| `src/smac/enemy_ai.nim` | the scripted army. `include`d into sim.nim |
| `src/smac/sim.nim` | the combat core, inherited; the micro branches are marked `MICRO:` |
| `src/smac/{decide,directives,control,baselines,llm}.nim` | the per-turn decision layer |
| `src/smac/server.nim` | mummy server, the `COGAME_*` contract, the turn loop |
| `client/replay_broadcast.html` | the starter's page **plus one appended game block** |
| `tools/build_manifest.py` | regenerates the manifest from README.md + docs/ |

`scenario.nim` and `enemy_ai.nim` are `include`d rather than imported because
they need the combat core above them and are needed by `step` below it. They
stay separate FILES so the CI float grep can read them on their own.

## Rules for changing things

* **`client/chrome_common.js` is byte-for-byte the starter's.** Its sha256 is
  pinned in `tests/test_viewer.nim`. Everything this game adds lives in the
  appended block at the bottom of `client/replay_broadcast.html`, under the
  banner comment. A from-scratch page that reuses the starter's ids is a
  rewrite, not a fork.
* **`client/broadcast_core.js` differs from the starter's in exactly one
  identifier** (`CTF_WIRE` -> `SMAC_WIRE`). The test asserts the count.
* **The beat builder is `smacBeat`, never `markBeat`.** chrome_common.js hoists
  `markBeat` into the page's closure; redeclaring it shadows the real one and
  every scrubber beat silently becomes an unlabelled div.
* **Editing `microResultsJson` means editing `coworld_manifest_template.json` in
  the same commit.** The results schema is `additionalProperties: false` and the
  certifier rejects any unknown field. `tests/test_manifest.nim` compares the
  two key sets.
* **Bump `GameVersion` in `src/smac/sim_types.nim`** whenever the hashed state
  or the tick order changes, with a changelog entry saying what and why. Old
  replays stop re-simulating; that is the point of the version.
* **Never add a variant without adding it to the manifest test's sweep** — it
  already builds and steps EVERY variant, including the 25-unit `corridor`.

## CI is the only harness

There is no Nim, no Docker and no emsdk in the authoring sandbox. `ci.yml` runs:

* every `tests/*.nim` twice, debug and release (`test_perf.nim` is
  release-only, via the `NIM_TESTS_RELEASE_ONLY` repo variable);
* `tools/ci/docker_smoke.sh` — a raw-Docker episode from the certification
  fixture in the production image, with `SMOKE_SEATS=5` and
  `SMOKE_REQUIRE_REPLAY_JSON=0` (the replay is binary `COWLDSMC`);
* the `wasm-viewer` job — builds the bundle, **executes** it in headless
  chromium against the replay `docker-smoke` produced, then runs
  `tools/wasm_replay_smoke.cjs` as the native-to-wasm hash gate.

`tools/replay_summary.py` (standard library only) is the strict-UTF-8 JSON view
of a binary replay, for forensics and for the phase-60 check.

## Degrade, never hang

Every wait is bounded: the two LLM batch deadlines (6 s + 3 s), the outer 10 s
per-turn deadline, `lobbyJoinTimeoutTicks` on the connect wait, mummy's socket
timeouts, the 690 s engine stop and the game-over hold. On a seat's second
failure its directive becomes the `focusfire` scripted directive and a
`fallback` record names the cause. **No failure mode leaves a unit unactuated**:
the control layer always has a directive — this turn's, else last turn's, else
`focusfire`'s.
