## End conditions, the battle log, and the record -> re-derive assertion for
## EVERY end reason (particle-worlds 13c66d7, 2026-08-26).
import std/[json, unittest]
import smac_helpers

const
  LegalReasons = [ReasonComplete, ReasonDeadline, ReasonFault]
  LegalRules = [EndRuleVictory, EndRuleWipe, EndRuleFullTime,
                EndRuleWallClock, EndRuleSimFault, EndRuleHostError]

suite "endings":
  test "the last enemy dying ends the battle victory on that tick":
    var sim = newMicroSim()
    for id in 1 .. 4:
      sim.killUnit(sim.enemyIndex(id))
    check sim.phase == Playing
    sim.killUnit(sim.enemyIndex(5))
    check sim.theirAlive == 0
    sim.checkBattleEnd()
    check sim.phase == GameOver
    check sim.endRule == EndRuleVictory
    check sim.battlesWon == 1

  test "our last unit dying ends it wipe":
    var sim = newMicroSim()
    for i in 0 ..< 5:
      sim.killUnit(i)
    sim.checkBattleEnd()
    check sim.endRule == EndRuleWipe
    check sim.battlesWon == 0

  test "a tick in which both happen is a wipe":
    var sim = newMicroSim()
    for i in 0 ..< 5:
      sim.killUnit(i)
    for id in 1 .. 5:
      sim.killUnit(sim.enemyIndex(id))
    check sim.ourAlive == 0
    check sim.theirAlive == 0
    sim.checkBattleEnd()
    # Step 6.8 evaluates `wipe` FIRST, so mutual annihilation is never a win.
    check sim.endRule == EndRuleWipe

  test "the clock running out with both sides standing is full_time":
    var sim = newMicroSim(microConfigJson(maxTicks = 48))
    # Exactly the ceiling: the battle ends ON this tick, before the game-over
    # hold expires and the server resets to the lobby for the next one.
    sim.stepIdle(48)
    check sim.phase == GameOver
    check sim.endRule == EndRuleFullTime
    check sim.ourAlive > 0
    check sim.theirAlive > 0

  test "battleLog records exactly one entry per battle played":
    var sim = newMicroSim()
    check sim.battleLog.len == 0
    sim.endRule = EndRuleFullTime
    sim.archiveBattle()
    check sim.battleLog.len == 1
    check sim.battleLog[0].enemyStartHp == 480
    check sim.battleLog[0].ourStartHp == 480
    sim.archiveBattle()
    check sim.battleLog.len == 2

  test "the wall-clock stop is applied by ONE proc and banks what is there":
    var sim = newMicroSim()
    sim.stepIdle(24)
    sim.applyStop(sim.tickCount)
    check sim.endReason == ReasonDeadline
    check sim.endRule == EndRuleWallClock
    check sim.phase == GameOver
    check sim.battleLog.len == 1
    check sim.battleLog[0].won == false
    # Applying it twice (record, then playback) is idempotent, which is what
    # makes a deadline-ended replay reproduce the recorded hash at the stop
    # tick instead of warning on it.
    let hash = sim.gameHash()
    sim.applyStop(sim.tickCount)
    check sim.gameHash() == hash
    check sim.battleLog.len == 1

  test "a tripped invariant is a real SimGuardError":
    var sim = newMicroSim()
    sim.checkMicroInvariants()      # clean state: no raise
    sim.ourAlive = 99
    expect SimGuardError:
      sim.checkMicroInvariants()

  test "every end reason and rule is a member of its declared enum":
    var sim = newMicroSim(microConfigJson(maxTicks = 48))
    sim.stepIdle(60)
    let results = parseJson(sim.microResultsJson())
    check results["reason"].getStr() in LegalReasons
    check results["endRule"].getStr() in LegalRules
    for rule in results["battleResults"]:
      check rule.getStr() in LegalRules

  test "an episode that never finished a battle still reports one":
    var sim = newMicroSim()
    let results = parseJson(sim.microResultsJson())
    check results["battleResults"].len >= 1
    check results["battleTicks"].len == results["battleResults"].len
    check results["battleDamagePct"].len == results["battleResults"].len
    check results["battleLossPct"].len == results["battleResults"].len
