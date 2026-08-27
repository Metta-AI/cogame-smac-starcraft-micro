## Offline MAP-art preview: bakes a named map exactly as the viewer does
## (fresh sim, no episode, no Docker) and writes one PNG. The iteration loop
## for map geometry.
##
##   nim r --path:src tools/preview_map.nim <mapPath> <out.png>

import
  std/os,
  pixie,
  ../src/smac/sim,
  toolutil

proc main() =
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: preview_map <mapPath> <out.png>", 1)
  chdirGameDir()
  var config = defaultGameConfig()
  config.mapPath = args[0]
  var sim = initSimServer(config)
  renderBoardFrame(sim).writeFile(absolutePath(args[1]))
  echo args[1]

main()
