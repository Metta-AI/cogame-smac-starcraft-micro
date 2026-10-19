# Prompt diversity and post-training candidates

The native host and text bridge use five training introductions: `canonical`,
`plain`, `numbered`, `questions`, and `reordered`. `heldout-briefing` and
`heldout-reference` are evaluation-only. All seven preserve the rules, numeric
constants, strategy guidance, operator instructions, observations, and JSON grammar.

Set `promptVariant` in the game configuration. `mixed` requires an explicit
nonnegative `promptSeed` and selects `promptSeed % 5`. Selection stays fixed
through all three battles and never consumes the simulation's random stream.
Omitting the selection preserves the original canonical system message.

The selection belongs to the decision engine, outside the binary simulator and
replay format. Each turn freezes all five observations before installing any
orders, including when an individual seat retries.

## Complete-game text bridge

```sh
nimby sync nimby.lock
nim c -d:release --parallelBuild:1 --path:src -o:smac-train-bridge tools/train_bridge.nim
./smac-train-bridge coworld_manifest_template.json default
```

The JSONL protocol accepts `reset`, `teacher`, and `step`. A reset specifies
`players: 5`, a string `seed`, optional prompt selection, and `split`
(`train`, `validation`, or `test`). Training rejects held-out introductions.
Decisions include messages, prompt hashes, a semantic view, and the action schema.
All five actions are collected before the native controller advances the game.
Terminal responses report all five scores after the complete three-battle episode.

## Private source candidates

```sh
nim c -d:release --parallelBuild:1 --path:src -o:smac-export tools/export_posttrain.nim
./smac-export /tmp/smac-default-candidates 10 1 default mixed 7
```

Supported variants are `default`, `outnumbered`, `corridor`, and `heavy`.
Export requires a clean committed checkout and a new output directory. It writes
private `trajectories.jsonl` candidates and a manifest, never ready-to-train splits.
Records identify the scripted `focusfire` teacher, exact messages and hashes,
parsed and installed actions, source revision, and complete episode outcomes.
Scenario families group the same seed across every game and wording variant.
The shared Coworld review and split gates own admission to training.

## Native evidence and evaluation

Set `SMAC_HOST_TRACE_PATH` to a new private file and `SMAC_SOURCE_REVISION` to the
tested source commit. The host records actual request bodies, response headers,
raw replies, parsed actions, retries, installed orders, and final results.
These records include operator instructions and must remain private. Public replay
and results do not acquire the trace or prompt selection.

Run `python3 tools/test_prompt_games.py ./smac-train-bridge` for complete-game
wording equivalence and simultaneous-information checks. Model experiments should
pair scenario seeds, seats, budgets, and training steps; compare canonical-only
training against mixed training on both seen and held-out wording. Report score,
completion, parse, retry, and fallback rates without discarding failed episodes.
Deterministic teacher checks establish interface correctness, not improved model
play or resistance to training collapse.
