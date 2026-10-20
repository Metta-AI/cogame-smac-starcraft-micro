# Prompt diversity and training

The `smac-starcraft-micro-rules-v2` bank provides five training presentations:
`canonical`, `plain`, `numbered`, `questions`, and `reordered`.
`heldout-briefing` and `heldout-reference` are evaluation-only.
Scoring, control, and visibility explanations vary. Numeric rules, strategy
guidance, operator instructions, and command syntax remain fixed.

All presentations correct the original claim that a ranger dies after two
seconds of melee contact: a blade takes about 7.5 seconds against a full-health
ranger. The canonical message otherwise remains unchanged.

Set `promptVariant` in game configuration. `mixed` requires a nonnegative
`promptSeed`, choosing `promptSeed % 5` once for all three battles without
consuming simulation randomness. Selection belongs to the decision engine,
outside the binary simulator and replay format.

Rate-limit spacing precedes the inference budget. The published 12-second
spacing otherwise exhausts the 10-second request budget before subsequent
turns can request decisions. Spacing, deadlines, and episode budgets are unchanged.

## Collection and evaluation

```sh
nim c -d:release --parallelBuild:1 --path:src -o:/tmp/smac-bridge tools/train_bridge.nim
python3 tools/test_prompt_games.py /tmp/smac-bridge
nim r --path:src tools/export_posttrain.nim /tmp/smac-data 10 1 default mixed 0
```

The persistent JSONL bridge command is `["/tmp/smac-bridge", "<source>/coworld_manifest_template.json", "default"]`
with five players. Other variants are `outnumbered`, `corridor`, and `heavy`.
Held-out resets require `split: "validation"` or `split: "test"`.
The bridge freezes all five observations before installing decisions.

Exports use the native simulator, focusfire teacher, and command parser.
They write `train.jsonl`, `validation.jsonl`, and `manifest.json`. Every fifth
scenario seed belongs to validation. Mixed wording cycles within each split,
so training receives all five presentations. Scenario families group the same
seed across variants. Episode IDs include selected wording and prompt seed,
so matched exports remain distinguishable. Rows retain exact message hashes; all five source views
are frozen before orders are installed. Existing output directories are rejected.
Held-out wording cannot enter training exports.

These are scripted imitation examples. Deterministic complete-game comparisons
check mechanics and provenance, not learned robustness. Match game seeds,
policies, and inference settings in learning comparisons; report failures and
fallbacks, and reserve held-out wording until training choices are frozen.
