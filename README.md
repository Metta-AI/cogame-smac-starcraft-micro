# smac-starcraft-micro

**Five cogs fight a scripted army three times, and the squad's score is one
number.**

Each of the five seats commands exactly ONE unit. Your five spawn in a column on
the west side of a fixed 1235 x 659 arena; a scripted enemy army spawns 475
pixels east of them — just outside a ranger's weapon range, so the very first
decision is a real one. Both sides walk, shoot and swing under the same physics.
Nothing regenerates and nothing respawns: a unit that dies is out for the rest of
that battle. A battle that kills the whole enemy army with anybody left alive is
a **victory**, and an episode is three battles long.

Everybody's score is the same score.

```
per battle:  0.60 x won  +  0.30 x (damage dealt / enemy pool)
                         +  0.10 x (1 - damage taken / our pool)
teamScore = mean over the three battles          ->  [0, 1], higher is better
```

A perfect episode — three victories with no damage taken — is exactly 1.000.
Three wipes with no damage dealt is exactly 0.000. Every seat reports the same
`teamScore`; the only per-seat term is a tie-break worth at most 0.0004, which
is deliberately smaller than one ranger shot of squad damage. Farming personal
credit loses more than it can gain.

## The three skills, none of them coded

* **Focus fire.** Five units on one enemy kill it in about three seconds. Five
  units on five different enemies kill nothing in the same window, and a dead
  enemy stops shooting back forever. Every enemy carries a numeric id (`E3`);
  naming it in `target_id` and shouting it in `say` is how five simultaneous
  decisions become one volley.
* **Kiting.** A ranger out-ranges a blade 380 px to 56 px but is 10 px/s slower.
  Backing off while the weapon cools is free damage — until the arena wall
  arrives.
* **Screening.** A blade that stands between the enemy and a ranger is the only
  thing that buys the ranger those seconds. A dead ranger deals no damage for
  the rest of the battle.

## A policy is just a prompt

Every five seconds each seat issues ONE order for its own unit, in a fixed JSON
grammar, and a deterministic controller executes it at tick rate for the next
five seconds — it walks the unit around walls, turns it to face what you asked,
and pulls the trigger when the shot will land. You never touch a motor or a
trigger directly.

```json
{"note": "everyone on E3, blades screen the rangers",
 "cogs": [{"id": "RANGER-alpha", "intent": "focus", "target_id": 3,
           "target": [640, 302], "face": [700, 300], "say": "E3"}]}
```

Intents: `focus`, `attack_move`, `kite`, `hold`, `screen`, `retreat`, `regroup`.
`docs/COMMANDING.md` explains what each one compiles to and what a good prompt
says.

Two scripted baselines ship in the same image, selected by environment variable
rather than by code: `focusfire` (the published default, the certification
player and the per-turn fallback) and `charge` (deliberately weaker, and
different in SHAPE so the ladder gets a spread). Both are documented in
`docs/RULES.md`, so cooperating with a scripted partner means cooperating with a
partner whose rules you know.

```bash
coworld upload-policy coworld-smac-starcraft-micro \
  --name my-smac --run /bin/smac-starcraft-micro-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

## Four scenarios

| id | squad | enemy army | enemy pool |
|---|---|---|---|
| `default` | 2 rangers, 3 blades | 2 rangers, 3 blades | 480 |
| `outnumbered` | 5 rangers | 6 rangers | 360 |
| `corridor` | 5 blades | 20 swarm | 600 |
| `heavy` | 2 rangers, 3 blades | 3 rangers, 4 blades | 660 |

They are this repo's adaptations of the SMAC shapes **2s3z**, **5m_vs_6m**,
**corridor** and **3s5z_vs_3s6z**. There is **no OpenBW, no Brood War binary, no
BWAPI and no Blizzard asset** anywhere in this repo, and **no bit-exact parity
with SMAC, SMACv2 or SMAX is claimed or tested** — see `docs/SCENARIOS.md`.

## Watching

The replay is a static WebAssembly bundle: the same Nim sim module compiled to
wasm re-derives every frame in the browser from the recorded per-unit actuator
masks and checks a hash every tick. The whole enemy army — every spawn, every
target choice, every swing — is re-derived from the seed rather than recorded,
which is why a hash mismatch is a real integrity signal and why the file stays
around 330 KB.

The board shows two army-strength bars (the bars ARE the score), five seat
plates with each policy's real name and damage dealt, an animated focus ring
whenever two or more of your units are shooting the same enemy, per-unit health
bars, a first-person view down a ranger's barrel, and a match feed that prints
the commander's own line every turn — which is where a spectator sees the LLM
playing.

## Repo tour

| path | what |
|---|---|
| `src/smac/` | the sim: units, the scripted enemy army, the scenario layer, the decision layer, the server |
| `src/smac_starcraft_micro.nim` | the game server entrypoint (`/bin/smac-starcraft-micro`) |
| `src/smac_starcraft_micro_player.nim` | the thin seat registrar (`/bin/smac-starcraft-micro-player`) |
| `client/` | the broadcast chrome |
| `replay-viewer/` | the emscripten entry for the static wasm bundle |
| `docs/` | rules, scenarios, protocol, prompt guide, and the design note |
| `tests/` | the Nim suite CI runs in debug and release |
