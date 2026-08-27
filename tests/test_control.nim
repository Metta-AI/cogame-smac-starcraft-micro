## The bounded-orders / legality sweep on the scripted baselines, and the
## pinned focusfire > charge regression.
import std/[random, sequtils, sets, unicode, unittest]
import smac_helpers

const
  ButtonPairsUpDown = ButtonUp or ButtonDown
  ButtonPairsLeftRight = ButtonLeft or ButtonRight
  LegalBits = ButtonUp or ButtonDown or ButtonLeft or ButtonRight or
    ButtonA or ButtonB or ButtonSelect

proc scatter(sim: var SimServer, rng: var Rand) =
  ## A pseudo-random but LEGAL world state: every unit somewhere walkable, with
  ## a random aim, hit points and cooldown, and a random subset alive.
  for i in 0 ..< sim.players.len:
    let spot = sim.nearestWalkable(
      ArenaBorder + PlayerHalf + rng.rand(MapWidth - 2 * (ArenaBorder + PlayerHalf) - 1),
      ArenaBorder + PlayerHalf + rng.rand(MapHeight - 2 * (ArenaBorder + PlayerHalf) - 1))
    sim.placePlayer(i, spot.x, spot.y)
    sim.players[i].aimBrads = rng.rand(255)
    sim.players[i].hp = 1 + rng.rand(sim.players[i].maxHp - 1)
    sim.players[i].alive = rng.rand(9) > 0
    sim.players[i].fireCooldown = rng.rand(20)
    sim.players[i].fireWindup = 0
    sim.players[i].arcTicksLeft = 0
  # Somebody on each side is always up, so the baselines always have work.
  sim.players[0].alive = true
  sim.players[sim.config.friendlyCount()].alive = true
  sim.updateArmiesNow()

suite "control":
  test "500 random states x both baselines x five seats emit legal orders":
    var
      sim = newMicroSim()
      ctl = initControlState(sim)
      rng = initRand(679961)
      livingIds: HashSet[int]
    for round in 0 ..< 500:
      sim.scatter(rng)
      ctl.observeEnemies(sim)
      livingIds.clear()
      for j in sim.config.friendlyCount() ..< sim.players.len:
        if sim.players[j].alive:
          livingIds.incl(sim.config.enemyIdOf(j))
      for kind in [blFocusFire, blCharge]:
        for seat in 0 ..< sim.config.friendlyCount():
          if not sim.players[seat].alive:
            continue
          let directive = scriptedDirective(ctl, sim, kind, @[seat])
          check directive.note.runeLen <= MaxNoteRunes
          check directive.orders.len == 1
          let order = directive.orders[0]
          check order.cogIndex == seat
          check order.id == sim.cogAlias(seat)
          check order.say.runeLen <= MaxSayRunes
          check order.intent in {intFocus, intAttackMove, intKite, intHold,
                                 intScreen, intRetreat, intRegroup}
          # A target_id is either absent or a LIVING enemy.
          if order.targetId > 0:
            check order.targetId in livingIds
          check order.targetX >= 0
          check order.targetX < MapWidth
          check order.targetY >= 0
          check order.targetY < MapHeight
          let mask = ctl.compileMask(sim, order, seat)
          check (mask and not LegalBits) == 0
          check (mask and ButtonPairsUpDown) != ButtonPairsUpDown
          check (mask and ButtonPairsLeftRight) != ButtonPairsLeftRight
          check (mask and ButtonC) == 0
          # The same (state, order) pair always yields the same byte.
          check ctl.compileMask(sim, order, seat) == mask

  test "retreat never fires, and the trigger respects cooldown and windup":
    var
      sim = newMicroSim()
      ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    sim.placePlayer(0, 500, 330)
    sim.placePlayer(sim.enemyIndex(1), 560, 330)
    sim.players[0].aimBrads = 0
    var order = CogOrder(cogIndex: 0, id: sim.cogAlias(0), intent: intRetreat,
                         targetId: 1, targetX: 200, targetY: 330)
    check (ctl.compileMask(sim, order, 0) and ButtonA) == 0
    order.intent = intFocus
    sim.players[0].fireCooldown = 5
    check (ctl.compileMask(sim, order, 0) and ButtonA) == 0
    sim.players[0].fireCooldown = 0
    sim.players[0].fireWindup = 3
    check (ctl.compileMask(sim, order, 0) and ButtonA) == 0

  test "a ranger never pulls the trigger with nothing on the ray":
    var
      sim = newMicroSim()
      ctl = initControlState(sim)
    for j in sim.config.friendlyCount() ..< sim.players.len:
      sim.players[j].alive = false
    sim.updateArmiesNow()
    ctl.observeEnemies(sim)
    sim.placePlayer(0, 500, 330)
    sim.players[0].fireCooldown = 0
    let order = CogOrder(cogIndex: 0, id: sim.cogAlias(0), intent: intHold,
                         targetId: -1, targetX: 500, targetY: 330)
    check (ctl.compileMask(sim, order, 0) and ButtonA) == 0

  test "a kite ranger stands still when the shot is ready and moves otherwise":
    var
      sim = newMicroSim()
      ctl = initControlState(sim)
    let foe = sim.enemyIndex(1)
    for j in sim.config.friendlyCount() ..< sim.players.len:
      sim.players[j].alive = j == foe
    sim.updateArmiesNow()
    sim.placePlayer(0, 500, 330)
    sim.placePlayer(foe, 700, 330)      # 200 px: inside the 380 px range
    sim.players[0].aimBrads = 0
    ctl.observeEnemies(sim)
    let order = CogOrder(cogIndex: 0, id: sim.cogAlias(0), intent: intKite,
                         targetId: 1, targetX: 700, targetY: 330)
    sim.players[0].fireCooldown = 0
    let ready = ctl.compileMask(sim, order, 0)
    check (ready and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) == 0
    sim.players[0].fireCooldown = 10
    let cooling = ctl.compileMask(sim, order, 0)
    check (cooling and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0

  test "a unit ordered to an unreachable target still moves every tick":
    var
      sim = newMicroSim()
      ctl = initControlState(sim)
    sim.placePlayer(0, 400, 330)
    var moved = 0
    let order = CogOrder(cogIndex: 0, id: sim.cogAlias(0), intent: intHold,
                         targetId: -1, targetX: 0, targetY: 0)
    var prev = sim.idle()
    for _ in 0 ..< 120:
      ctl.observeEnemies(sim)
      var now = sim.idle()
      let mask = ctl.compileMask(sim, order, 0)
      if (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0:
        inc moved
      now[0] = decodeInputMask(mask)
      sim.step(now, prev)
      prev = now
    check moved >= 100

  test "focusfire x 5 kills at least three enemies in `default`":
    var
      sim = newMicroSim(microConfigJson(
        maxTicks = 1440, maxGames = 1, friendlySpawnX = 380, enemySpawnX = 855))
      ctl = initControlState(sim)
      prev = sim.idle()
    while sim.phase == Playing and sim.tickCount < 3000:
      ctl.observeEnemies(sim)
      var now = sim.idle()
      let directive = scriptedDirective(
        ctl, sim, blFocusFire, toSeq(0 ..< sim.config.friendlyCount()))
      for order in directive.orders:
        now[order.cogIndex] = decodeInputMask(
          ctl.compileMask(sim, order, order.cogIndex))
      sim.step(now, prev)
      prev = now
    # A pinned regression against a baseline that does nothing.
    check sim.config.enemyCount() - sim.theirAlive >= 3

  test "focusfire x 5 scores at least as high as charge x 5 at seed 679961":
    proc play(kind: Baseline, configJson: string): int =
      var
        sim = newMicroSim(configJson)
        ctl = initControlState(sim)
        prev = sim.idle()
      while sim.phase == Playing and sim.tickCount < 3000:
        ctl.observeEnemies(sim)
        var now = sim.idle()
        let directive = scriptedDirective(
          ctl, sim, kind, toSeq(0 ..< sim.config.friendlyCount()))
        for order in directive.orders:
          now[order.cogIndex] = decodeInputMask(
            ctl.compileMask(sim, order, order.cogIndex))
        sim.step(now, prev)
        prev = now
      if sim.endRule.len == 0:
        sim.endRule = EndRuleFullTime
      sim.archiveBattle()
      microTeamScorePermille(sim)

    for scenario in [
        (@["ranger", "ranger", "blade", "blade", "blade"],
         @["ranger", "ranger", "blade", "blade", "blade"]),
        (@["ranger", "ranger", "ranger", "ranger", "ranger"],
         @["ranger", "ranger", "ranger", "ranger", "ranger", "ranger"]),
        (@["blade", "blade", "blade", "blade", "blade"],
         @["swarm", "swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
           "swarm", "swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
           "swarm", "swarm", "swarm", "swarm", "swarm", "swarm"]),
        (@["ranger", "ranger", "blade", "blade", "blade"],
         @["ranger", "ranger", "ranger", "blade", "blade", "blade", "blade"])]:
      let config = microConfigJson(
        maxTicks = 720, maxGames = 1,
        roles = scenario[0], enemyRoles = scenario[1],
        friendlySpawnX = 380, enemySpawnX = 855)
      let
        focus = play(blFocusFire, config)
        charge = play(blCharge, config)
      # `default` is the variant the league ranks, so the pinned regression is
      # STRICT there: a squad that concentrates its damage must beat one that
      # splits it across the whole army. The other three are asserted
      # non-inferior, because their compositions leave less room for a target
      # choice to matter (five rangers with nothing to screen; twenty swarm
      # units that all arrive at once).
      if scenario[0] == @["ranger", "ranger", "blade", "blade", "blade"] and
          scenario[1] == @["ranger", "ranger", "blade", "blade", "blade"]:
        check focus > charge
      else:
        check focus >= charge
