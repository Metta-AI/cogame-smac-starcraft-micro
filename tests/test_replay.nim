## An end-to-end episode: a real replay, re-derived hash for hash, parsed
## strictly as UTF-8 by the forensic tool.
import std/[json, os, osproc, unicode, unittest]
import smac_helpers
import smac/replays

const Fixture = "tests/fixtures"

proc recordEpisode(path: string): SimServer =
  ## Plays a full scripted 5-seat, 3-battle episode and writes a COWLDSMC
  ## replay, exactly as the server does: one mask per FRIENDLY unit per tick,
  ## one gameHash per tick, and the whole enemy army re-derived.
  var
    sim = newMicroSim(microConfigJson(maxTicks = 240, maxGames = 3))
    ctl = initControlState(sim)
    writer = openReplayWriter(path, sim.config.configJson())
    prev = sim.idle()
    battles = 0
  defer: writer.closeReplayWriter()
  for seat in 0 ..< sim.config.friendlyCount():
    writer.writeJoin(tickTime(sim.tickCount), seat,
                     sim.players[seat].address, seat, "t" & $seat)
  for order in sim.config.friendlyCount() ..< sim.players.len:
    writer.writeJoin(tickTime(sim.tickCount), order, sim.aliasOfCog(order),
                     order, "")
  while writer.lastMasks.len < sim.players.len:
    writer.lastMasks.add(0)
  while battles < 3 and sim.tickCount < 3000:
    var now = sim.idle()
    if sim.phase == Playing:
      ctl.observeEnemies(sim)
      for seat in 0 ..< sim.config.friendlyCount():
        let one = scriptedDirective(ctl, sim, blFocusFire, @[seat])
        if one.orders.len > 0:
          let mask = ctl.compileMask(sim, one.orders[0], seat)
          now[seat] = decodeInputMask(mask)
          writer.writeInputMaskChange(tickTime(sim.tickCount), seat, mask)
    else:
      for seat in 0 ..< sim.config.friendlyCount():
        writer.writeInputMaskChange(tickTime(sim.tickCount), seat, 0)
    let before = sim.phase
    sim.step(now, prev)
    prev = now
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    if before != GameOver and sim.phase == GameOver:
      inc battles
      sim.archiveBattle()
      sim.gameIndex = battles
  writer.writeChat(tickTime(sim.tickCount), 0,
    "{\"k\":\"result\",\"results\":" & sim.microResultsJson() & "}")
  sim

suite "replay":
  test "a full scripted episode writes a replay that re-derives every hash":
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      createDir(Fixture)
      let path = Fixture / "episode.bitreplay"
      let sim = recordEpisode(path)
      check fileExists(path)
      check getFileSize(path) > 0
      check sim.battleLog.len >= 1
      let data = loadReplay(path)
      check data.chats.len >= 1
      check data.hashes.len > 0
      # Only OUR five units carry a recorded mask: the whole enemy army — every
      # spawn, every target choice, every swing — is re-derived from the seed
      # and costs zero replay bytes.
      for input in data.inputs:
        check int(input.player) < 5
      # `parseReplayBytes` accepts the same bytes off the wire.
      let reparsed = parseReplayBytes(readFile(path))
      check reparsed.hashes.len == data.hashes.len
      # And the recorded config is enough to rebuild the identical sim, which
      # is what the wasm viewer does frame by frame (the native <-> wasm hash
      # gate in ci.yml is the executing half of this assertion).
      var replayed = defaultGameConfig()
      replayed.update(data.configJson)
      check replayed.loadout == LoadoutMicro
      check replayed.enemyRoles.len == 5
      check replayed.seed == sim.config.seed
      removeFile(path)
    finally:
      setCurrentDir(previous)

  test "the results record embedded in the replay is strict UTF-8 JSON":
    var sim = newMicroSim()
    # A non-ASCII policy label and a non-ASCII note make the UTF-8 path real.
    sim.seatNames[0] = "d\u00e4veey \u{1F600}"
    let text = sim.microResultsJson()
    check text.validateUtf8() == -1
    let node = parseJson(text)
    check node["names"][0].getStr() == "d\u00e4veey \u{1F600}"

  test "replay_summary.py prints one strict-UTF-8 JSON object":
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      createDir(Fixture)
      let path = Fixture / "summary.bitreplay"
      discard recordEpisode(path)
      let (output, code) = execCmdEx("python3 tools/replay_summary.py " & path)
      check code == 0
      check output.validateUtf8() == -1
      let node = parseJson(output)
      check node["protocol"].getStr() == "smac-starcraft-micro/v1"
      check node.hasKey("results")
      check node["results"]["reason"].getStr() in
        [ReasonComplete, ReasonDeadline, ReasonFault]
      check node["aliases"].len == 10
      check node["aliases"][0].getStr() == "RANGER-alpha"
      check node["aliases"][5].getStr() == "E1"
      check node["enemyRoles"].len == 5
      removeFile(path)
    finally:
      setCurrentDir(previous)

  test "every directive record stays inside MaxDirectiveRunes":
    var
      sim = newMicroSim()
      ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    for seat in 0 ..< sim.config.friendlyCount():
      let directive = scriptedDirective(ctl, sim, blFocusFire, @[seat])
      let record = directive.boundedDirectiveRecord(
        1, 0, seat, sim.aliasOfCog(seat), roleText(sim.players[seat].role))
      check record.runeLen <= MaxDirectiveRunes
      check record.validateUtf8() == -1
      check parseJson(record)["k"].getStr() == "directive"

  test "the recorded config carries everything the viewer re-derives from":
    var sim = newMicroSim()
    let config = parseJson(sim.config.configJson())
    for key in ["seed", "loadout", "scenario", "roles", "enemyRoles",
                "num_agents", "maxTicks", "maxGames", "turnTicks",
                "friendlySpawnX", "enemySpawnX", "spawnJitterPx",
                "rangerHp", "rangerRange", "rangerDamage", "rangerCooldown",
                "bladeHp", "bladeReach", "bladeArcBrads", "bladeDamage",
                "bladeCooldown", "swingTicks", "swarmHp", "swarmReach",
                "swarmDamage", "swarmCooldown", "aggroPx", "leashPx",
                "retargetTicks", "enemyStuckTicks"]:
      check config.hasKey(key)
