## Startup, the config contract and the two `/client/` routes.
import std/[json, os, strutils, unittest]
import smac_helpers
import smac/wire_constants

suite "startup":
  test "a missing or unparseable config is a clean error, not a traceback":
    var config = defaultGameConfig()
    expect SmacError:
      config.update("{ this is not json")
    var another = defaultGameConfig()
    expect SmacError:
      another.update("[1, 2, 3]")

  test "an illegal micro config is rejected with a readable message":
    var config = defaultGameConfig()
    # roles must have exactly num_agents entries.
    expect SmacError:
      config.update("""{"loadout":"micro","num_agents":5,
        "roles":["ranger"],"enemyRoles":["ranger"]}""")
    var weights = defaultGameConfig()
    expect SmacError:
      weights.update("""{"loadout":"micro","num_agents":5,
        "roles":["ranger","ranger","blade","blade","blade"],
        "enemyRoles":["ranger"],"winWeightPermille":500}""")
    var budget = defaultGameConfig()
    expect SmacError:
      budget.update("""{"loadout":"micro","num_agents":5,
        "roles":["ranger","ranger","blade","blade","blade"],
        "enemyRoles":["ranger"],"wallClockBudgetSeconds":1200}""")

  test "the seed is honoured when pinned and echoed into the replay config":
    let sim = newMicroSim(microConfigJson(seed = 12345))
    check sim.config.seed == 12345
    check parseJson(sim.config.configJson())["seed"].getInt() == 12345

  test "the micro loadout derives the inherited weapon knobs from its roles":
    let sim = newMicroSim()
    check sim.config.gunRange == sim.config.rangerRange
    check sim.config.fireCooldownTicks == sim.config.rangerCooldown
    check sim.config.lives == 1
    check sim.config.respawnTicks == 0
    check sim.config.floorPaint == false
    check sim.config.hill == false
    check sim.config.barrierPickups == 0
    check sim.config.barrageMaxPerSec == 0

  test "no pickup family is placed and no heart is in play":
    let sim = newMicroSim()
    check sim.medKitSpawns.len == 0
    check sim.shieldSpawns.len == 0
    check sim.sprayPaintSpawns.len == 0
    check sim.barrierSpawns.len == 0
    for spawn in sim.grenadeSpawns:
      check not spawn.present
    for team in Red .. Blue:
      check sim.flags[team].captured

  test "both /client/ pages exist on disk and neither is the player socket":
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      check fileExists("client/replay_broadcast.html")
      check fileExists("client/league_replayer.html")
      check fileExists("client/chrome_common.js")
      check fileExists("client/broadcast_core.js")
      let page = readFile("client/replay_broadcast.html")
      check "<!-- WIRE_CONSTANTS -->" in page
      check "<!-- CHROME_COMMON -->" in page
      check "<!-- BROADCAST_CORE -->" in page
    finally:
      setCurrentDir(previous)

  test "the two entrypoints and the viewer hook are where the image wants them":
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      check fileExists("src/smac_starcraft_micro.nim")
      check fileExists("src/smac_starcraft_micro_player.nim")
      check fileExists("replay-viewer/smac_replay.nim")
      let dockerfile = readFile("Dockerfile")
      check "/bin/smac-starcraft-micro" in dockerfile
      check "/bin/smac-starcraft-micro-player" in dockerfile
      check "CMD [\"/bin/smac-starcraft-micro\"]" in dockerfile
      # `coworld build` requires os.X_OK on the hook.
      check fpUserExec in getFilePermissions("tools/build_replay_viewer.sh")
      check fpUserExec in getFilePermissions("tools/ci/docker_smoke.sh")
    finally:
      setCurrentDir(previous)

  test "the wire constants the browser reads come from the engine's own consts":
    check "window.SMAC_WIRE={" in WireConstantsJs
    check "speeds:" in WireConstantsJs
    check "fps:24" in WireConstantsJs
