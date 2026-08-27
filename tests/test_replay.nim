## An end-to-end episode: a real replay, re-derived hash for hash, parsed
## strictly as UTF-8 by the forensic tool.
import std/[json, os, osproc, unicode, unittest]
import smac_helpers
import smac/[replay_runtime, replays]

const Fixture = "tests/fixtures"

proc writeSquadJoins(writer: var ReplayWriter, sim: SimServer) =
  ## One join record per unit on the board, exactly as the server writes them
  ## when the squad (re-)registers: our five carry their seat token, the
  ## scripted army joins trusted with none.
  for i in 0 ..< sim.players.len:
    writer.writeJoin(
      tickTime(sim.tickCount), i, sim.players[i].address, i,
      (if i < sim.config.numAgents: "t" & $i else: ""))
  while writer.lastMasks.len < sim.players.len:
    writer.lastMasks.add(0)

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
  writer.writeSquadJoins(sim)
  while battles < 3 and sim.tickCount < 3000:
    if sim.phase == Lobby and sim.players.len == 0:
      ## `resetToLobby` emptied the roster when the last battle ended. The
      ## server re-registers the squad here and records the joins; playback
      ## rebuilds the identical roster from them on the identical tick.
      sim.seatMicroSquad()
      writer.writeSquadJoins(sim)
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
      # Exactly what the server's tick loop does after writing this tick's
      # hash, by the same proc playback calls (scenario.advanceBattle).
      sim.advanceBattle()
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
      # Item 7: an all-scripted episode played to its NATURAL end reports
      # `complete` — not `deadline`, not `fault`. A regression that ends every
      # episode on the wall clock or on a tripped invariant would otherwise
      # keep every job green (the smoke script only PRINTS the reason).
      let results = parseJson(sim.microResultsJson())
      check results["reason"].getStr() == ReasonComplete
      check results["games"].getInt() == 3
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
      # is what the wasm viewer does frame by frame (the next test is the
      # executing half, natively; the wasm gate in ci.yml is the same
      # assertion on the 32-bit target).
      var replayed = defaultGameConfig()
      replayed.update(data.configJson)
      check replayed.loadout == LoadoutMicro
      check replayed.enemyRoles.len == 5
      check replayed.seed == sim.config.seed
      removeFile(path)
    finally:
      setCurrentDir(previous)

  test "replaying the recording reproduces EVERY recorded hash, all 3 battles":
    ## The executing half of acceptance item 2, natively: the recorded episode
    ## is re-opened through the SHIPPED replay runtime — the identical
    ## `initReplayRuntime` the wasm viewer calls — and stepped to the last
    ## recorded tick from the config, the seed and the friendly masks alone
    ## (the whole enemy army is re-derived). Consuming every recorded hash
    ## with `hashValidationFailed` false IS "reproduces the recorded per-tick
    ## state frame by frame".
    ##
    ## Multi-battle on purpose: a state transition applied on record but not on
    ## playback shows up one tick after the FIRST battle boundary and nowhere
    ## earlier (r1 review B1, which shipped green because no test replayed
    ## anything).
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      createDir(Fixture)
      let path = Fixture / "rederive.bitreplay"
      let recorded = recordEpisode(path)
      check recorded.battleLog.len == 3
      let data = loadReplay(path)
      var run = initReplayRuntime(
        data, mismatchQuit = false, gameEventLoggingEnabled = false)
      let maxTick = run.player.replayMaxTick()
      check maxTick > 0
      while run.player.playing and run.sim.tickCount < maxTick:
        run.player.stepReplay(run.sim)
      # `checkReplayHash` latches BOTH of these on the first disagreeing tick
      # and stops checking, so they are the whole chain's verdict.
      check run.player.hashMismatchTick == -1
      check not run.player.hashValidationFailed
      check run.player.hashIndex == data.hashes.len
      check run.sim.tickCount == maxTick
      # The re-derived sim really crossed all three battle boundaries.
      check run.sim.battleIndex == 3
      check run.sim.battlesWon == recorded.battlesWon
      removeFile(path)
    finally:
      setCurrentDir(previous)

  test "a hash the sim cannot reproduce IS reported, even past playback":
    ## The gate has to be able to fail. One recorded hash deep in the file is
    ## corrupted; the display player is nowhere near that tick, so only the
    ## whole-match precompute walk crosses it — and `replayMismatchTick` (what
    ## `smac_mismatch_tick()` and the chrome's integrity banner read) must
    ## still name the tick. Before r1 review B3 the walk's detection stayed on
    ## its private builder and the exported accessor read -1 out of a process
    ## that had already echoed the mismatch.
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      createDir(Fixture)
      let path = Fixture / "corrupt.bitreplay"
      discard recordEpisode(path)
      var data = loadReplay(path)
      check data.hashes.len > 8
      let victim = data.hashes.len - 4
      let victimTick = int(data.hashes[victim].tick)
      data.hashes[victim].hash = not data.hashes[victim].hash
      var run = initReplayRuntime(
        data, mismatchQuit = false, gameEventLoggingEnabled = false)
      # The display player is parked on the spectator start tick, hundreds of
      # ticks short of the corruption.
      check run.sim.tickCount < victimTick
      check run.player.hashMismatchTick == -1
      # The walk crosses every recorded tick and publishes what it finds.
      run.player.advanceReplayScan(int.high)
      check run.player.scanComplete
      check run.player.scanMismatchTick == victimTick
      check run.player.replayMismatchTick == victimTick
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
