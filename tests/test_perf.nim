## Release-only: a full corridor episode with 25 units on the board.
import std/[monotimes, times, unittest]
import smac_helpers

suite "perf":
  test "3 x 1440 ticks of corridor with mask compilation stays under 120 s":
    let config = microConfigJson(
      maxTicks = 1440, maxGames = 3,
      roles = @["blade", "blade", "blade", "blade", "blade"],
      enemyRoles = @["swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
                     "swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
                     "swarm", "swarm", "swarm", "swarm", "swarm", "swarm",
                     "swarm", "swarm"],
      friendlySpawnX = 380, enemySpawnX = 855)
    let started = getMonoTime()
    var
      sim = newMicroSim(config)
      ctl = initControlState(sim)
      prev = sim.idle()
      battles = 0
    check sim.players.len == 25
    while battles < 3 and sim.tickCount < 3 * 1440 + 300:
      var now = sim.idle()
      if sim.phase == Playing:
        ctl.observeEnemies(sim)
        for seat in 0 ..< sim.config.friendlyCount():
          let directive = scriptedDirective(ctl, sim, blFocusFire, @[seat])
          if directive.orders.len > 0:
            now[seat] = decodeInputMask(
              ctl.compileMask(sim, directive.orders[0], seat))
      let before = sim.phase
      sim.step(now, prev)
      prev = now
      if before != GameOver and sim.phase == GameOver:
        inc battles
        sim.archiveBattle()
        sim.gameIndex = battles
        sim.microSpawnBattle()
        sim.phase = Playing
        sim.gameStartTick = sim.tickCount
    let elapsed = (getMonoTime() - started).inSeconds
    echo "corridor episode in ", elapsed, " s"
    check elapsed < 120
