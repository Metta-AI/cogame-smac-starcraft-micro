## The per-seat view contract.
import std/[json, unittest]
import smac_helpers

proc viewOf(sim: SimServer, seat: int): JsonNode =
  var engine = initDecisionEngine(sim)
  parseJson(engine.seatViewJson(sim, seat, 0, 12))

suite "observation":
  test "with fogOfWar false every unit on both sides is visible":
    var sim = newMicroSim()
    for i in 0 ..< sim.players.len:
      for j in 0 ..< sim.players.len:
        check sim.playerVisibleTo(i, j)

  test "the enemies array is sorted by distance and capped at 24":
    var sim = newMicroSim(microConfigJson(
      roles = @["blade", "blade", "blade", "blade", "blade"],
      enemyRoles = @["swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
                     "swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
                     "swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
                     "swarm", "swarm"]))
    let view = viewOf(sim, 0)
    check view["enemies"].len == 20
    check view["enemies"].len <= MaxEnemyViewEntries
    var previous = -1
    for entry in view["enemies"]:
      let d = entry["dist_px"].getInt()
      check d >= previous
      previous = d

  test "focused_by agrees with a full rescan of the sim":
    var sim = newMicroSim()
    sim.updateArmiesNow()
    let view = viewOf(sim, 0)
    for entry in view["enemies"]:
      let cog = sim.config.cogOfEnemyId(entry["id"].getInt())
      check entry["focused_by"].getInt() == sim.focusCount[cog]
    var rescan = 0
    for i in 0 ..< sim.config.friendlyCount():
      if sim.microAttackTarget(i) >= 0:
        inc rescan
    var total = 0
    for cog in sim.config.friendlyCount() ..< sim.players.len:
      total += sim.focusCount[cog]
    check total == rescan

  test "the seat view names only aliases, never a policy identity":
    var sim = newMicroSim()
    for seat in 0 ..< 5:
      let text = $viewOf(sim, seat)
      check "policy0" notin text
      check "policy4" notin text
      check "RANGER-" in text or "BLADE-" in text

  test "the seed, the RNG and the AI's counters never reach a seat":
    var sim = newMicroSim()
    sim.stepIdle(30)
    let text = $viewOf(sim, 0)
    check "seed" notin text
    check "retarget" notin text
    check "stuck" notin text
    check "jitter" notin text
    check $sim.config.seed notin text

  test "squad[].last_note is LAST turn's and never this turn's":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    # Nothing has been decided yet, so every squadmate's last note is null.
    let first = parseJson(engine.seatViewJson(sim, 0, 0, 12))
    check first["squad"].len == 4
    for mate in first["squad"]:
      check mate["last_note"].kind == JNull
    check first["your_last_directive"].kind == JNull

  test "the armies block is the score, in absolute and percent":
    var sim = newMicroSim()
    let view = viewOf(sim, 0)
    check view["armies"]["ours"]["hp"].getInt() == sim.ourHp
    check view["armies"]["theirs"]["hp"].getInt() == sim.theirHp
    check view["armies"]["ours"]["hp_pct"].getInt() == 100
    check view["armies"]["theirs"]["alive"].getInt() == 5
    check view["score"]["win_weight"].getFloat() == 0.6
    check view["score"]["dmg_weight"].getFloat() == 0.3
    check view["score"]["surv_weight"].getFloat() == 0.1
