# Metta post-training data

The native simulator and published `focusfire` policy can export supervised
examples for all four certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim /tmp/smac-default 10 1 default
nim r -d:release --path:src tools/export_posttrain.nim /tmp/smac-outnumbered 10 1 outnumbered
nim r -d:release --path:src tools/export_posttrain.nim /tmp/smac-corridor 10 1 corridor
nim r -d:release --path:src tools/export_posttrain.nim /tmp/smac-heavy 10 1 heavy
```

Each run reads its manifest variant config and plays complete seeded,
five-seat, three-battle episodes. The exporter records the hosted system
prompt, each seat's battle view, and a `focusfire` action accepted by the
game's reply parser. Parsed actions drive combat. Splits are by episode seed.
The manifest records source revision, variant, score, wins, and row counts.
Existing output directories are never overwritten.

Train any output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/smac-default \
  --output /tmp/smac-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

In local 10-episode exports, default produced 535 training and 145 validation
examples, outnumbered 610 and 155, corridor 250 and 60, heavy 535 and 130.
All 2,390 examples fit a 4096-token model context. One CPU optimizer update
reduced held-out loss from 5.5603 to 5.4867, 5.4878 to 5.4187, 5.4929 to
5.4151, and 5.5253 to 5.4487 respectively. The teacher won 17/30, 0/30,
30/30, and 0/30 battles, so outnumbered and heavy need a stronger teacher for
competitive play. These exports prove data and training interfaces, not
improved league performance.
