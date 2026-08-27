## The scripted army: targeting, hysteresis, the stuck escape, determinism,
## and the integer-only guarantee.
import std/[os, strutils, unittest]
import smac_helpers

const MicroSources = ["src/smac/units.nim", "src/smac/enemy_ai.nim",
                      "src/smac/scenario.nim"]

suite "enemy ai":
  test "an enemy picks the nearest visible friendly unit inside aggroPx":
    var sim = newMicroSim()
    let foe = sim.enemyIndex(1)
    for i in 0 ..< sim.players.len:
      sim.placePlayer(i, 900, 100)
      sim.players[i].alive = i >= sim.config.friendlyCount()
    sim.players[0].alive = true
    sim.players[3].alive = true
    sim.placePlayer(foe, 620, 330)
    sim.placePlayer(0, 560, 330)      # 60 px away
    sim.placePlayer(3, 260, 330)      # 360 px away
    sim.players[foe].targetSeat = -1
    sim.players[foe].retargetCounter = 0
    sim.microEnemyRetarget(foe)
    check sim.players[foe].targetSeat == 0

  test "a target outside leashPx is dropped":
    var sim = newMicroSim()
    let foe = sim.enemyIndex(1)
    sim.placePlayer(foe, 100, 330)
    sim.placePlayer(0, 1100, 330)     # 1000 px: past both aggro and leash
    for i in 1 ..< sim.config.friendlyCount():
      sim.players[i].alive = false
    sim.players[foe].targetSeat = 0
    sim.players[foe].retargetCounter = 0
    sim.microEnemyRetarget(foe)
    check sim.players[foe].targetSeat == -1

  test "the 1.5x hysteresis prevents a retarget between two equidistant units":
    var sim = newMicroSim()
    let foe = sim.enemyIndex(1)
    sim.placePlayer(foe, 600, 330)
    sim.placePlayer(0, 500, 330)
    sim.placePlayer(1, 500, 336)      # essentially the same distance
    for i in 2 ..< sim.config.friendlyCount():
      sim.players[i].alive = false
    sim.players[foe].targetSeat = 1
    sim.players[foe].retargetCounter = 0
    sim.microEnemyRetarget(foe)
    # Seat 0 is marginally closer but nowhere near 1.5x, so the held target
    # survives: an enemy must not oscillate between two units side by side.
    check sim.players[foe].targetSeat == 1

  test "a much closer candidate DOES take the target":
    var sim = newMicroSim()
    let foe = sim.enemyIndex(1)
    sim.placePlayer(foe, 600, 330)
    sim.placePlayer(1, 200, 330)      # 400 px
    sim.placePlayer(0, 620, 330)      # 20 px: twenty times closer
    for i in 2 ..< sim.config.friendlyCount():
      sim.players[i].alive = false
    sim.players[foe].targetSeat = 1
    sim.players[foe].retargetCounter = 0
    sim.microEnemyRetarget(foe)
    check sim.players[foe].targetSeat == 0

  test "an enemy with no target walks toward the friendly spawn anchor":
    var sim = newMicroSim()
    let foe = sim.enemyIndex(1)
    for i in 0 ..< sim.config.friendlyCount():
      sim.players[i].alive = false
    sim.placePlayer(foe, 900, 330)
    sim.players[foe].targetSeat = -1
    sim.players[foe].retargetCounter = 0
    let input = sim.microEnemyInput(foe)
    # friendlySpawnX is west of 900, so the army walks west.
    check input.left
    check not input.right

  test "a stuck enemy deflects a quarter turn and stops being stuck":
    var sim = newMicroSim()
    let foe = sim.enemyIndex(1)
    sim.placePlayer(foe, 900, 330)
    sim.players[foe].lastPosX = 900
    sim.players[foe].lastPosY = 330
    sim.players[foe].stuckCount = sim.config.enemyStuckTicks - 1
    discard sim.microEnemyInput(foe)
    check sim.players[foe].stuckRotTicks > 0
    check sim.players[foe].stuckCount == 0

  test "two runs from the same seed produce identical enemy streams":
    var a = newMicroSim(microConfigJson(maxTicks = 240))
    var b = newMicroSim(microConfigJson(maxTicks = 240))
    a.stepIdle(120)
    b.stepIdle(120)
    check a.gameHash() == b.gameHash()
    var c = newMicroSim(microConfigJson(maxTicks = 240, seed = 424242))
    c.stepIdle(120)
    check c.gameHash() != a.gameHash()

  test "the hashed micro sources carry no floating-point token":
    ## `int` is 32-bit under --cpu:wasm32 and the wasm viewer re-derives every
    ## tick from the recorded masks, so no NEW floating-point value may enter
    ## the hashed path (design SS Determinism, native <-> wasm).
    const Banned = ["float", "sqrt", "hypot", "sin", "cos", "tan",
                    "arctan", "arcsin", "floor", "ceil", "round",
                    # These two are libm behind an integer-looking name, and
                    # libm is not bit-identical between glibc and wasm.
                    "aimVector", "bradsOfVector", "gauss"]
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      for path in MicroSources:
        for line in readFile(path).splitLines():
          let code = line.split("##")[0].split("#")[0]
          var token = ""
          for ch in code & " ":
            if ch in IdentChars:
              token.add(ch)
            else:
              if token.len > 0:
                check token notin Banned
              token = ""
    finally:
      setCurrentDir(previous)
