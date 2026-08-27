## The scoring formula, its sign, and the epsilon-dominance inequality.
import std/[json, random, unittest]
import smac_helpers

suite "scoring":
  test "battle_b is 0 at the floor and 1000 at the ceiling":
    let config = microConfig(microConfigJson())
    check config.battleScorePermille(false, 0, 480, 480, 480) == 0
    check config.battleScorePermille(true, 480, 480, 0, 480) == 1000

  test "a victory scores at least 0.90 and a wipe at most 0.30":
    let config = microConfig(microConfigJson())
    # A victory implies dmgFrac == 1, so 0.60 + 0.30 + at least 0.
    check config.battleScorePermille(true, 480, 480, 480, 480) >= 900
    # A wipe banks no win and loses every point of health.
    check config.battleScorePermille(false, 480, 480, 480, 480) <= 300

  test "monotone in dmgFrac, non-increasing in lossFrac, never negative":
    let config = microConfig(microConfigJson())
    var previous = -1
    for dealt in countup(0, 480, 16):
      let value = config.battleScorePermille(false, dealt, 480, 240, 480)
      check value >= 0
      check value >= previous
      previous = value
    previous = 1001
    for taken in countup(0, 480, 16):
      let value = config.battleScorePermille(false, 240, 480, taken, 480)
      check value >= 0
      check value <= previous
      previous = value

  test "teamScore stays inside [0, 1] over ten thousand random draws":
    let config = microConfig(microConfigJson())
    var rng = initRand(679961)
    for _ in 0 ..< 10_000:
      let
        pool = 1 + rng.rand(900)
        ours = 1 + rng.rand(900)
        value = config.battleScorePermille(
          rng.rand(1) == 1, rng.rand(pool), pool, rng.rand(ours), ours)
      check value >= 0
      check value <= 1000

  test "the epsilon range is strictly dominated by one ranger shot":
    # One ranger shot (4 hp) in the variant with the LARGEST enemy pool
    # (`heavy`, 660 hp) is worth 4/660 * 0.30 / 3 = 0.000606 to EVERY seat,
    # while the entire personal-credit range is 0.0004. The ordering is
    # therefore lexicographic: squad damage first, personal credit only as a
    # tie-break, so a seat that breaks focus to farm credit loses more than it
    # can gain.
    let config = microConfig(microConfigJson())
    let
      epsilon = config.creditEpsilonPerMyriad.float / 10_000.0
      oneShot = config.rangerDamage.float / 660.0 *
        (config.dmgWeightPermille.float / 1000.0) / 3.0
    check epsilon == 0.0004
    check epsilon < oneShot

  test "all five seats report exactly the same teamScore and win":
    var sim = newMicroSim()
    sim.killUnit(sim.enemyIndex(1))
    sim.killUnit(0)
    sim.endRule = EndRuleFullTime
    sim.archiveBattle()
    let results = parseJson(sim.microResultsJson())
    let team = results["teamScore"].getFloat()
    check results["scores"].len == 5
    check results["win"].len == 5
    for i in 0 ..< 5:
      # Every seat's score is teamScore plus a credit inside the epsilon range.
      check results["scores"][i].getFloat() >= team
      check results["scores"][i].getFloat() <= team + 0.0004 + 1e-12
      check results["win"][i].getBool() == results["win"][0].getBool()
    check results["win"][0].getBool() == (team >= 0.5)

  test "unplayed battles score 0 because the mean always divides by maxGames":
    var sim = newMicroSim(microConfigJson(maxTicks = 240, maxGames = 3))
    for id in 1 .. 5:
      sim.killUnit(sim.enemyIndex(id))
    sim.endRule = EndRuleVictory
    sim.archiveBattle()
    let results = parseJson(sim.microResultsJson())
    # One perfect battle out of three is at most one third of a perfect episode.
    check results["teamScore"].getFloat() <= 0.34
    check results["battleResults"].len == 1
    check results["games"].getInt() == 1

  test "a fault scores what was banked with win false everywhere":
    var sim = newMicroSim()
    for id in 1 .. 5:
      sim.killUnit(sim.enemyIndex(id))
    sim.endRule = EndRuleVictory
    sim.archiveBattle()
    sim.endReason = ReasonFault
    sim.endRule = EndRuleSimFault
    let results = parseJson(sim.microResultsJson())
    check results["reason"].getStr() == "fault"
    for i in 0 ..< 5:
      check results["win"][i].getBool() == false
    check results["teamScore"].getFloat() > 0.0

  test "the results document has exactly the 26 declared keys":
    var sim = newMicroSim()
    let results = parseJson(sim.microResultsJson())
    check results.len == 26
    for key in ["names", "scores", "win", "role", "alias", "damageDealt",
                "damageTaken", "kills", "deaths", "shots", "llmTurns",
                "fallbackTurns", "teamScore", "battlesWon", "battleResults",
                "battleTicks", "battleDamagePct", "battleLossPct",
                "enemyKilled", "enemyTotal", "scenario", "reason", "endRule",
                "games", "finalTick", "seed"]:
      check results.hasKey(key)
