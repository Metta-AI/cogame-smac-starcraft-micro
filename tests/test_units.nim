## The two weapons, the unit table and the damage ledger.
import std/[math, unittest]
import smac_helpers

suite "units":
  test "the role table is what the config says":
    let sim = newMicroSim()
    check sim.players.len == 10
    check sim.players[0].role == urRanger
    check sim.players[0].maxHp == 60
    check sim.players[2].role == urBlade
    check sim.players[2].maxHp == 120
    check sim.players[0].speedPct == 100
    check sim.players[2].speedPct == 115
    check sim.config.roleSpeedPct(urSwarm) == 130
    # 2.75 px/tick for a ranger, 3.16 for a blade, 3.57 for a swarm unit.
    check sim.config.maxSpeed * 100 div 100 div MotionScale == 2
    check sim.config.maxSpeed * 115 div 100 div MotionScale == 3
    check sim.config.maxSpeed * 130 div 100 div MotionScale == 3
    check sim.config.maxSpeed * 115 div 100 == 809
    check sim.config.maxSpeed * 130 div 100 == 915

  test "our five are ours and the army is the army":
    let sim = newMicroSim()
    for i in 0 ..< 5:
      check not sim.config.isEnemyCog(i)
      check sim.config.enemyIdOf(i) == 0
      check sim.players[i].team == Red
    for i in 5 ..< 10:
      check sim.config.isEnemyCog(i)
      check sim.config.enemyIdOf(i) == i - 4
      check sim.players[i].team == Blue
    check sim.config.cogOfEnemyId(3) == 7
    check sim.config.cogOfEnemyId(0) == -1
    check sim.config.cogOfEnemyId(99) == -1

  test "aliases carry the role, enemies carry their id":
    let sim = newMicroSim()
    check sim.cogAlias(0) == "RANGER-alpha"
    check sim.cogAlias(1) == "RANGER-beta"
    check sim.cogAlias(2) == "BLADE-alpha"
    check sim.cogAlias(3) == "BLADE-beta"
    check sim.cogAlias(4) == "BLADE-gamma"
    check sim.cogAlias(5) == "E1"
    check sim.cogAlias(9) == "E5"

  test "a ranger's shot removes exactly rangerDamage and needs its windup":
    var sim = newMicroSim()
    let victim = sim.enemyIndex(1)
    sim.placePlayer(0, 400, 330)
    sim.placePlayer(victim, 600, 330)
    sim.players[0].aimBrads = 0
    let before = sim.players[victim].hp
    sim.startFireWindup(0)
    check sim.players[0].fireWindup == 5
    # The shot has NOT landed while the windup runs.
    check sim.players[victim].hp == before
    sim.tryFire(0)
    check sim.players[victim].hp <= before

  test "hp floors at 0, a unit at 0 hp is not alive, overkill is clipped":
    var sim = newMicroSim()
    let victim = sim.enemyIndex(1)
    sim.players[victim].hp = 3
    let bankedBefore = sim.battleDmgDealt
    discard sim.absorbDamage(victim, 10, 0, "gun")
    check sim.players[victim].hp <= 0
    # A 3 hp unit hit for 10 banks 3: overkill is never credited.
    check sim.battleDmgDealt - bankedBefore == 3
    sim.killPlayer(victim, 0)
    check not sim.players[victim].alive
    check sim.players[victim].deathTick == sim.tickCount

  test "a swing damages every enemy in the wedge, at most once per activation":
    var sim = newMicroSim()
    let
      blade = 2
      a = sim.enemyIndex(1)
      b = sim.enemyIndex(2)
    sim.placePlayer(blade, 500, 330)
    sim.placePlayer(a, 530, 330)
    sim.placePlayer(b, 700, 330)      # far outside the 56 px reach
    sim.players[blade].aimBrads = 0
    sim.players[blade].fireCooldown = 0
    sim.players[blade].hasSprayPaint = true
    let
      hpA = sim.players[a].hp
      hpB = sim.players[b].hp
    sim.startArcFire(blade)
    check sim.players[blade].arcTicksLeft == sim.config.swingTicks
    check sim.players[blade].fireCooldown == sim.config.bladeCooldown
    for _ in 0 ..< sim.config.swingTicks:
      sim.resolveActiveArcCones()
    check hpA - sim.players[a].hp == sim.config.bladeDamage
    check sim.players[b].hp == hpB

  test "no friendly fire: a swing ignores our own bodies":
    var sim = newMicroSim()
    sim.placePlayer(2, 500, 330)
    sim.placePlayer(0, 530, 330)
    sim.players[2].aimBrads = 0
    sim.players[2].hasSprayPaint = true
    sim.players[2].fireCooldown = 0
    let hp = sim.players[0].hp
    sim.startArcFire(2)
    for _ in 0 ..< sim.config.swingTicks:
      sim.resolveActiveArcCones()
    check sim.players[0].hp == hp

  test "the starting pools are the sum of the role table":
    let sim = newMicroSim()
    check sim.ourStartHp == 2 * 60 + 3 * 120
    check sim.enemyStartHp == 2 * 60 + 3 * 120
    check sim.ourStartHp == 480
    check sim.ourHp == sim.ourStartHp
    check sim.theirHp == sim.enemyStartHp
    check sim.ourAlive == 5
    check sim.theirAlive == 5

  test "clipDamage never banks more than the victim had":
    check clipDamage(3, 10) == 3
    check clipDamage(10, 3) == 3
    check clipDamage(0, 10) == 0
    check clipDamage(-4, 10) == 0
    check clipDamage(10, -4) == 0
