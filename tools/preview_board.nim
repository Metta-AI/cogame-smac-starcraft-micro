## Offline board-art preview: re-simulates a replay and writes one PNG per
## requested tick, composited exactly as the viewer does. The fast iteration
## loop for board art (map_art / rig_art / data assets): no Docker, no wasm
## build, no browser.
##
##   nim r --path:src tools/preview_board.nim <replay> <outdir> [tick ...]
##
## With no ticks given, renders a spread across the episode.

import
  std/[algorithm, os, strutils, strformat],
  pixie,
  ../src/smac/sim,
  toolutil

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    quit("usage: preview_board <replay> <outdir> [tick ...]", 1)
  let
    replayPath = absolutePath(args[0])
    outDir = absolutePath(args[1])
  chdirGameDir()
  createDir(outDir)
  var ticks: seq[int]
  for a in args[2 .. ^1]:
    ticks.add parseInt(a)
  var (sim, replay) = openReplay(replayPath)
  if ticks.len == 0:
    # No tick list: sample a spread across the recorded episode.
    let total = replay.data.hashes.len
    for f in [0.05, 0.15, 0.3, 0.5, 0.7, 0.9]:
      ticks.add int(float(total) * f)
  ticks.sort()
  for target in ticks:
    while sim.tickCount < target and replay.playing:
      replay.stepReplay(sim)
    let path = outDir / &"board_{sim.tickCount:05}.png"
    renderBoardFrame(sim).writeFile(path)
    echo path

main()
