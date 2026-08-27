## The static half of the viewer smoke: chrome provenance and the elements this
## game removed. No browser — ci.yml's wasm-viewer job is the executing half.
import std/[os, osproc, strutils, unittest]

const
  GameDir = currentSourcePath.parentDir.parentDir
  StarterChromeSha =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  BannerLine =
    "smac-starcraft-micro additions to the inherited coworld-ctf chrome"
  # The aliases chrome_common.js hoists into the page's closure. NOTHING in the
  # appended game block may redeclare any of them (cogame-tandem, 2026-08-23).
  ChromeAliases = ["markBeat", "renderBeatMarkers", "ingestBeats",
                   "setVerdict", "recordMomentum", "ingestLullSpans",
                   "ingestLeadSeries", "stripSeatSuffix", "teamPolicies",
                   "teamName", "teamHeadline", "setName"]
  # Every beat kind this game emits, and no other.
  BeatKinds = ["battlestart", "firstblood", "loss", "lastcog", "battleover"]
  DeadBeatKinds = ["steal", "return", "capture", "hillflip", "hillhold"]

proc read(path: string): string =
  readFile(GameDir / path)

suite "viewer":
  let
    page = read("client/replay_broadcast.html")
    chrome = read("client/chrome_common.js")
    core = read("client/broadcast_core.js")
    bannerAt = page.find(BannerLine)
    inherited = page[0 ..< max(0, bannerAt)]
    appended = page[max(0, bannerAt) .. ^1]

  test "chrome_common.js is byte-identical to the starter's copy":
    # Not edited, not reformatted: everything this game adds lives in the
    # appended block. The sha256 is the pin.
    check chrome.len > 10_000
    check "window.ChromeCommon" in chrome
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let (shaOut, code) = execCmdEx("sha256sum client/chrome_common.js")
      check code == 0
      check shaOut.split()[0] == StarterChromeSha
    finally:
      setCurrentDir(previous)

  test "broadcast_core.js differs from the starter's in ONE identifier":
    check "window.SMAC_WIRE" in core
    check "CTF_WIRE" notin core
    check core.count("SMAC_WIRE") == 2

  test "the page is the starter's, with a game block APPENDED":
    check bannerAt > 0
    check inherited.len > appended.len
    for id in ["viewport", "stage", "board", "lightpool", "grain",
               "lockerroom", "chrome", "scorebug", "bannerlane",
               "killfeed", "fpv", "povBadge", "mmwarn", "transport",
               "scrub", "momentum", "lulls", "scrub-win", "scrub-head",
               "endcard"]:
      check ("id=\"" & id & "\"") in inherited
    check "plates-l" in inherited
    check "plates-r" in inherited
    check "id=\"clock\"" in inherited

  test "the removed elements really are gone":
    for id in ["id=\"viewpanel\"", "id=\"minimap\"", "id=\"minimap-canvas\"",
               "id=\"zoombar\"", "id=\"zoom-in\"", "id=\"zoom-out\"",
               "id=\"zoom-slider\"", "id=\"zoom-read\""]:
      check id notin page
    check "#viewpanel {" notin page
    check "#minimap {" notin page
    check ".flagicon {" notin page
    check "#endcard .ec-heart {" notin page
    check ".plate .hillchip" notin page
    for kind in DeadBeatKinds:
      check (".beat-marker." & kind) notin page

  test "CSS exists for every beat kind the sim emits and for no other":
    for kind in BeatKinds:
      check (".beat-marker." & kind) in appended

  test "the transport rules the pin names are all still there":
    check "--band" in inherited
    check "--topband" in inherited
    check "--hudscale" in inherited
    check "bottom: var(--band, 0px)" in inherited
    check "#stage.tiny" in inherited
    # relayout() owns the hudscale clamp: max(0.5, min(1.6, boardW / 760)).
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in inherited
    # Every seek dismisses the endcard.
    check "$('endcard').classList.remove('on')" in inherited

  test "the appended block adds the ten readouts this game promised":
    check "#armybars" in appended
    check "arow-fill" in appended
    check "#focusring" in appended
    check "FOCUS FIRE" in appended
    check "smacBeat" in appended
    check "SmacChrome" in appended
    check "battle " in appended

  test "the army bars are a scorebug ROW, never an overlay on the plates":
    ## B6: absolutely positioned inside #chrome they were drawn across the seat
    ## plates. As #scorebug's own full-width grid row the band measures them, so
    ## relayout() reserves the height and nothing overlaps.
    check "grid-column: 1 / -1;" in appended
    check "$('scorebug') || $('chrome')" in appended
    let bars = appended[appended.find("#armybars {") .. ^1]
    check "position: absolute" notin bars[0 ..< bars.find("}")]
    check "--topband" notin bars[0 ..< bars.find("}")]

  test "the 360 px rules are present, labels included":
    check ".plate-name {" in appended
    check "flex: 1 1 auto;" in appended
    check "min-width: 3.2em;" in appended
    # Item 11's second clause: the plate LABEL is hidden under 640 px, the way
    # the starter hides `.lives-label`. The micro plate's `Dmg` span carries
    # both class names, so both are pinned here.
    check "#stage.tiny .plate .lives-label" in appended
    check "#stage.tiny .plate .smac-lbl { display: none; }" in appended
    check "#stage.tiny .plate .smac-kills { display: none; }" in appended
    check "#stage.tiny .armyrow .arow-notch { display: none; }" in appended

  test "the game block shadows no chrome alias":
    for alias in ChromeAliases:
      check ("function " & alias) notin appended
      check ("var " & alias) notin appended
      check ("let " & alias) notin appended
    # The beat builder is smacBeat, never markBeat.
    check "function smacBeat(" in appended

  test "no ctf_ or CTF_ identifier survives in client, replay-viewer or src":
    ## chrome_common.js is EXCLUDED: it is pinned byte-for-byte to the
    ## starter's copy above, and its one `window.CTF_WIRE` read falls back to
    ## the same defaults the engine ships (speeds and fps), so the pin and this
    ## grep are both satisfied by leaving it alone.
    for dir in ["client", "replay-viewer", "src"]:
      for path in walkDirRec(GameDir / dir):
        if path.endsWith("chrome_common.js"):
          continue
        if path.splitFile().ext notin [".js", ".nim", ".nims", ".html"]:
          continue
        let body = readFile(path)
        check "ctf_" notin body
        check "CTF_" notin body
