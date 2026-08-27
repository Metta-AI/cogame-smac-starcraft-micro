## The WORST-CASE TEXT FIXTURE recorder (acceptance checklist item 15).
##
## `tools/ci/docker_smoke.sh` runs without an `ANTHROPIC_API_KEY`, so every
## seat in every replay CI can produce falls back to the scripted baseline and
## the whole class of chrome that exists to show what a MODEL said — the board
## speech bubbles and the commander feed — is never exercised by any gate.
## cogchemists (2026-08-24) shipped four bubbles clipped to slivers with a
## fully green board for exactly that reason.
##
## So this writes a replay built to hurt:
##
## * every one of the five units shouts a FULL-CAP say (ShoutMaxChars = 10
##   runes of the widest printable glyph) at the SAME turn, every turn;
## * every seat's directive carries a FULL-CAP note (MaxNoteRunes = 160 runes,
##   including a wide emoji — the note keeps non-ASCII, the say does not);
## * both lines spawn at the ARENA EDGES: our five in the left border, the
##   enemy army in the right one, `spawnSpacingPx` wide enough that the ranks
##   clamp into the top and bottom corners. A bubble drawn upward from a cog on
##   the top row has nowhere to go, which is the whole defect class.
##
## Every string is checked HERE, at full length, before the bytes are written:
## a fixture whose remark was quietly shortened passes while testing nothing.
## The bubble rect of every live shout is checked against the board rect
## through `shoutBubbleRectFor` — the same geometry the draw pass uses.
##
## The bundle-side half is `replay-viewer/text_fixture.html`, driven by
## `tools/ci/viewer_smoke.mjs --strict-text-bounds` in its own ci.yml step; it
## loads the REAL renderer, plays this replay at three canvas sizes and asserts
## the same invariants in the browser through `smac_text_report()`.
##
##   nim r tools/record_text_fixture.nim [out.replay]

import
  std/[json, os, strutils, unicode],
  smac/[directives, global, replays, sim]

const
  DefaultOut = "dist/text-fixture/text_fixture.replay"
  Turn = 60                 ## ticks between turns: shorter than ShoutTicks, so
                            ## every unit has a LIVE bubble at every tick past
                            ## the first turn.
  Ticks = 240
  WideRune = "W"            ## the widest glyph the shout font sets; the
                            ## reserved band (shoutBubbleMaxHeight) is measured
                            ## with the same one.

proc fixtureSay(seat: int): string =
  ## Exactly MaxSayRunes runes, all of them the widest the font draws. The say
  ## path is printable-ASCII BY DESIGN (directives.sanitizeSay strips
  ## everything outside 32..126 and sim.sanitizeShout does it again), so the
  ## worst case for a bubble is width, not codepoint length.
  repeat(WideRune, MaxSayRunes - 1) & $seat

proc fixtureNote(): string =
  ## Exactly MaxNoteRunes runes, opening and closing on a 4-byte emoji: the
  ## note keeps non-ASCII all the way into the feed, so this is where a byte
  ## truncation would show as mojibake.
  "\u{1F600}" & repeat(WideRune, MaxNoteRunes - 2) & "\u{1F600}"

proc fixtureConfigJson(): string =
  ## Five seats at the LEFT arena edge, the enemy army at the right one, ranks
  ## spread far enough that the outer ones clamp into the corners.
  var
    roles = newJArray()
    enemies = newJArray()
    tokens = newJArray()
    players = newJArray()
    slots = newJArray()
  for role in ["ranger", "ranger", "blade", "blade", "blade"]:
    roles.add(%role)
    enemies.add(%role)
  for i in 0 ..< 5:
    tokens.add(%("t" & $i))
    players.add(%*{"name": "Unit " & $chr(ord('A') + i)})
    slots.add(%*{"team": "red"})
  $(%*{
    "seed": 679961,
    "loadout": "micro",
    "scenario": "default",
    "num_agents": 5,
    "minPlayers": 5,
    "roles": roles,
    "enemyRoles": enemies,
    "maxTicks": Ticks,
    "maxGames": 1,
    "mapPath": "arena",
    "fogOfWar": false,
    "turnTicks": Turn,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 4,
    "lobbyJoinTimeoutTicks": 0,
    "friendlySpawnX": 8,
    "enemySpawnX": 1226,
    "spawnSpacingPx": 320,
    "spawnJitterPx": 0,
    "fastMode": true,
    "showPlayerLabels": false,
    "tokens": tokens,
    "players": players,
    "slots": slots
  })

proc seatSquad(sim: var SimServer) =
  for seat in 0 ..< sim.config.numAgents:
    let name =
      if seat < sim.config.slots.len and sim.config.slots[seat].name.len > 0:
        sim.config.slots[seat].name
      else:
        "policy" & $seat
    discard sim.addPlayer(name, seat, "t" & $seat)
    sim.seatNames[seat] = name
  for order in sim.config.numAgents ..< sim.config.microUnitCount():
    discard sim.addPlayer(sim.aliasOfCog(order), order, "", trusted = true)

var
  failures: seq[string] = @[]
  checkedFrames = 0

proc mustHold(condition: bool, message: string) =
  if not condition:
    failures.add(message)

proc checkFrame(sim: SimServer, tick: int) =
  ## Every live bubble, at full length, wholly inside the board — the two
  ## things a worst-case fixture exists to assert.
  var seen = 0
  for i in 0 ..< sim.players.len:
    for shout in sim.recentShouts:
      if shout.address != sim.players[i].address:
        continue
      inc seen
      mustHold(shout.text.runeLen == MaxSayRunes,
        "tick " & $tick & ": bubble text is " & $shout.text.runeLen &
          " runes, not the full " & $MaxSayRunes & ": " & shout.text)
      let rect = sim.shoutBubbleRectFor(i, shout.text)
      mustHold(
        rect.x >= 0 and rect.y >= 0 and
        rect.x + rect.w <= sim.gameMap.width and
        rect.y + rect.h <= sim.gameMap.height,
        "tick " & $tick & ": bubble for unit " & $i & " at (" & $rect.x & "," &
          $rect.y & ") " & $rect.w & "x" & $rect.h & " leaves the " &
          $sim.gameMap.width & "x" & $sim.gameMap.height & " board")
  mustHold(seen == sim.config.numAgents,
    "tick " & $tick & ": " & $seen & " live bubbles, expected one per unit (" &
      $sim.config.numAgents & ")")

proc record(outPath: string): SimServer =
  var config = defaultGameConfig()
  config.update(fixtureConfigJson())
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  sim.seatSquad()
  sim.startGame()
  let
    say0 = fixtureSay(0)
    note = fixtureNote()
  mustHold(say0.runeLen == MaxSayRunes, "the fixture say is not full length")
  mustHold(note.runeLen == MaxNoteRunes, "the fixture note is not full length")
  mustHold(sanitizeSay(say0) == say0,
    "the fixture say does not survive sanitizeSay unchanged")
  mustHold(sanitizeNote(note) == note,
    "the fixture note does not survive sanitizeNote unchanged")

  var
    writer = openReplayWriter(outPath, sim.config.configJson())
    prev = newSeq[InputState](sim.players.len)
  defer: writer.closeReplayWriter()
  for i in 0 ..< sim.players.len:
    writer.writeJoin(
      tickTime(sim.tickCount), i, sim.players[i].address, i,
      (if i < sim.config.numAgents: "t" & $i else: ""))
  while writer.lastMasks.len < sim.players.len:
    writer.lastMasks.add(0)

  while sim.tickCount < Ticks and sim.phase != GameOver:
    if sim.phase == Playing and sim.gameTicksElapsed() mod Turn == 0:
      ## The server's turn boundary, in its order: one directive record per
      ## seat (feed), then each order's `say` applied as a REAL in-game shout
      ## and written by cog index so playback re-applies it identically.
      let turnIndex = sim.gameTicksElapsed() div Turn
      for seat in 0 ..< sim.config.numAgents:
        var directive = SquadDirective(source: dsLlm, note: note)
        directive.orders.add CogOrder(
          cogIndex: seat,
          id: sim.cogAlias(seat),
          intent: intHold,
          targetId: -1,
          targetX: sim.players[seat].x,
          targetY: sim.players[seat].y,
          say: fixtureSay(seat)
        )
        let record = directive.boundedDirectiveRecord(
          1, turnIndex, seat, sim.aliasOfCog(seat),
          roleText(sim.config.roleOfCog(seat)))
        mustHold(note in record,
          "the 160-rune note was shrunk out of the directive record")
        writer.writeChat(tickTime(sim.tickCount), seat, record)
        sim.pushFeedDirective(record)
        for order in directive.orders:
          if sim.applyShout(order.cogIndex, order.say):
            writer.writeChat(
              tickTime(sim.tickCount), order.cogIndex, order.say)
    let now = newSeq[InputState](sim.players.len)
    for cogIndex in 0 ..< sim.config.numAgents:
      writer.writeInputMaskChange(tickTime(sim.tickCount), cogIndex, 0)
    if sim.phase == Playing and sim.tickCount > Turn:
      checkFrame(sim, sim.tickCount)
      inc checkedFrames
    sim.step(now, prev)
    prev = now
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  writer.writeChat(tickTime(sim.tickCount), 0,
    "{\"k\":\"result\",\"results\":" & sim.microResultsJson() & "}")
  mustHold(checkedFrames > 0, "no frame carried a bubble to check")
  sim

proc main() =
  let outPath = if paramCount() >= 1: paramStr(1) else: DefaultOut
  if outPath.parentDir.len > 0:
    createDir(outPath.parentDir)
  let sim = record(outPath)
  echo "text fixture: ", outPath, " (", getFileSize(outPath), " bytes, ",
    sim.tickCount, " ticks, ", checkedFrames, " checked frames)"
  echo "  say  : ", MaxSayRunes, " runes x ", sim.config.numAgents, " units"
  echo "  note : ", MaxNoteRunes, " runes per seat, emoji at both ends"
  echo "  band : ", sim.shoutBubbleMaxHeight(), " px reserved"
  echo "  report: ", sim.shoutTextReportJson()
  if failures.len > 0:
    for line in failures:
      echo "FAIL: ", line
    quit(1)
  echo "text fixture OK: every string full length, every bubble inside the board"

main()
