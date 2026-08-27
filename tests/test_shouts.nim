## THE WORST-CASE TEXT FRAME (acceptance checklist item 15), natively.
##
## Every replay CI can produce carries ZERO model text: `docker_smoke.sh` runs
## without an `ANTHROPIC_API_KEY`, every seat falls back to the scripted
## baseline, and a scripted baseline emits no `say` and no `note`. So the whole
## class of chrome that exists to show what a model said — the board speech
## bubbles and the commander feed — is untested by every other gate.
## cogchemists (2026-08-24) drew each seat's bubble upward from the top of its
## cog, the cogs stood at the top of the arena, four sentences rendered as four
## white slivers, and everything was green.
##
## This builds the frame that hurts — a FULL-CAP say on EVERY unit at once with
## every unit shoved into an arena corner — and asserts the two things that
## matter: the strings are still full length, and every bubble is wholly inside
## the board. The browser half of the same assertions is
## `replay-viewer/text_fixture.html` (recorded by `tools/record_text_fixture.nim`,
## driven by `tools/ci/viewer_smoke.mjs --strict-text-bounds` in its own ci.yml
## step); both read the same `shoutTextReportJson`, so the two cannot drift.
import std/[json, strutils, unicode, unittest]
import smac_helpers
import smac/global

const
  Corners = [(20, 20), (1215, 20), (20, 639), (1215, 639), (617, 20)]
    ## Four corners plus the top centre: a bubble grows UPWARD from the cog, so
    ## the top row is where it has nowhere to go, and the left/right edges are
    ## where it must clamp sideways.

proc capSay(seat: int): string =
  ## MaxSayRunes runes of the widest glyph the shout font sets.
  repeat("W", MaxSayRunes - 1) & $seat

proc capNote(): string =
  ## MaxNoteRunes runes with a 4-byte emoji at each end: the note keeps
  ## non-ASCII all the way to the feed, so a byte cut would show here.
  "\u{1F600}" & repeat("W", MaxNoteRunes - 2) & "\u{1F600}"

proc shoutingAtCorners(): SimServer =
  ## Five units, one per corner-ish hostile spot, each with a live full-cap
  ## shout.
  result = newMicroSim()
  for seat in 0 ..< result.config.friendlyCount():
    let spot = Corners[seat mod Corners.len]
    result.placePlayer(seat, spot[0], spot[1])
    result.players[seat].lastShoutTick = -1
    doAssert result.applyShout(seat, capSay(seat))
  result.updateArmiesNow()

suite "shouts":
  test "the caps are what the code enforces, and the fixture strings hit them":
    check MaxSayRunes == ShoutMaxChars
    check capSay(0).runeLen == MaxSayRunes
    check capNote().runeLen == MaxNoteRunes
    # Full length THROUGH the truncation points, both of them.
    check sanitizeSay(capSay(3)) == capSay(3)
    check sanitizeNote(capNote()) == capNote()
    check sanitizeNote(capNote()).validateUtf8() == -1
    # And the say path really is printable-ASCII-only, in BOTH sanitisers, so
    # a bubble's worst case is glyph WIDTH and never a 4-byte codepoint.
    check sanitizeSay("ab\u{1F600}cd") == "abcd"
    check sanitizeShout("ab\u{1F600}cd") == "abcd"

  test "every unit shouting at full cap keeps its bubble inside the board":
    var sim = shoutingAtCorners()
    let report = parseJson(sim.shoutTextReportJson())
    check report["bubbles"].len == sim.config.friendlyCount()
    check report["board"]["w"].getInt() == sim.gameMap.width
    check report["board"]["h"].getInt() == sim.gameMap.height
    for bubble in report["bubbles"]:
      check bubble["runes"].getInt() == MaxSayRunes
      check bubble["inside"].getBool()
      check bubble["x"].getInt() >= 0
      check bubble["y"].getInt() >= 0
      check bubble["x"].getInt() + bubble["w"].getInt() <= sim.gameMap.width
      check bubble["y"].getInt() + bubble["h"].getInt() <= sim.gameMap.height

  test "a bubble with no room above FLIPS below instead of clipping":
    ## The cogchemists case, asserted rather than assumed: the tail tip of a cog
    ## on the top row leaves the bubble at a negative y unless the placement
    ## flips it.
    var sim = newMicroSim()
    sim.placePlayer(0, 617, 20)
    let
      anchor = sim.players[0].shoutAnchor()
      band = sim.shoutBubbleMaxHeight()
      rect = sim.shoutBubbleRectFor(0, capSay(0))
    check anchor.tailTipY - band < 0        # no room above: the hostile case
    check rect.y > anchor.tailTipY          # so it hangs BELOW the tail tip
    check rect.y >= 0
    check rect.y + rect.h <= sim.gameMap.height

  test "the reserved band is the cap's height, so no remark moves the bubble":
    ## The band is sized from the cap the server enforces, measured in the real
    ## font (shoutBubbleMaxHeight) — and it is what the placement decides
    ## above-or-below against, so which side a cog's bubble sits on cannot
    ## change with what it says. Today every bubble is exactly band-tall (the
    ## height is font + padding + tail, independent of the text); the day one
    ## wraps to two lines, the band is what keeps the scene from jumping.
    var sim = newMicroSim()
    let band = sim.shoutBubbleMaxHeight()
    check band > 0
    for text in ["a", "hi", capSay(1), "MMMMMMMMMM"]:
      check sim.shoutBubbleRectFor(0, text).h == band
    for seat in 0 ..< sim.config.friendlyCount():
      let spot = Corners[seat mod Corners.len]
      sim.placePlayer(seat, spot[0], spot[1])
      let
        short = sim.shoutBubbleRectFor(seat, "a")
        full = sim.shoutBubbleRectFor(seat, capSay(seat))
        tail = sim.players[seat].shoutAnchor().tailTipY
      # Same side of the tail tip, whatever the remark: no jump when one lands.
      check (short.y < tail) == (full.y < tail)
      check short.y == full.y
      check full.x >= 0
      check full.x + full.w <= sim.gameMap.width

  test "the full-cap note reaches the feed the client draws, unshortened":
    var sim = newMicroSim()
    var directive = SquadDirective(source: dsLlm, note: capNote())
    directive.orders.add CogOrder(
      cogIndex: 0, id: sim.cogAlias(0), intent: intHold, targetId: -1,
      targetX: sim.players[0].x, targetY: sim.players[0].y, say: capSay(0))
    let record = directive.boundedDirectiveRecord(
      1, 0, 0, sim.aliasOfCog(0), roleText(sim.players[0].role))
    check record.runeLen <= MaxDirectiveRunes
    check record.validateUtf8() == -1
    # The record is under the cap WITHOUT the shrink loop touching the note or
    # the say: a fixture whose remark was quietly shortened tests nothing.
    check parseJson(record)["note"].getStr() == capNote()
    check parseJson(record)["cogs"][0]["say"].getStr() == capSay(0)
    sim.pushFeedDirective(record)
    let report = parseJson(sim.shoutTextReportJson())
    check report["noteCap"].getInt() == MaxNoteRunes
    check report["feed"].len == 1
    check parseJson(report["feed"][0].getStr())["note"].getStr() == capNote()
