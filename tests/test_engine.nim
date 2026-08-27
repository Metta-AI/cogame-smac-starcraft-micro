## The turn loop: one parallel batch for all five seats, the spacing floor,
## the budget guard and the never-unactuated guarantee.
import std/[json, os, strutils, unittest]
import smac_helpers

suite "engine":
  test "the engine seats one policy per unit and defaults to focusfire":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    check engine.seats.len == 5
    for seat in 0 ..< 5:
      check engine.seats[seat].baseline == blFocusFire
      check engine.policyKind(seat) == "scripted"
      check sim.commandedCogs(seat) == @[seat]

  test "with no credentials every seat still gets a legal directive":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    # The client disables itself with no credentials, so the turn falls back
    # INSTANTLY with no network wait — which is what lets offline
    # certification finish in seconds.
    check engine.client.disabled
    let records = engine.turn(sim, 0, 12, 0)
    for seat in 0 ..< 5:
      check engine.haveDirective[seat]
      check engine.directives[seat].orders.len == 1
      check engine.directives[seat].orders[0].cogIndex == seat
    check records.len == 0        # scripted seats are not fallbacks

  test "an LLM seat with no key records a fallback, never a silent scripted turn":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "focus fire"
    let records = engine.turn(sim, 0, 12, 0)
    var causes: seq[string]
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback":
        causes.add(node["cause"].getStr())
        check node["seat"].getInt() == 0
        check node.hasKey("battle")
    check causes.len == 1
    check causes[0] == "no_credentials"
    check engine.directives[0].source == dsFallback

  test "the budget guard fires and the episode finishes on the scripted layer":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "focus fire"
    # Two more full turns would not fit inside the 690 s stop.
    let records = engine.turn(sim, 1, 12, sim.config.wallClockBudgetSeconds - 5)
    check engine.llmOff
    var guarded = false
    for record in records:
      if parseJson(record)["k"].getStr() == "budget_guard":
        guarded = true
    check guarded
    # And from here every seat is scripted, which costs microseconds.
    discard engine.turn(sim, 2, 12, sim.config.wallClockBudgetSeconds - 5)
    for seat in 0 ..< 5:
      check engine.haveDirective[seat]

  test "turnSpacingMs holds five seats under the sidecar's 30 req/min cap":
    # 5 seats x 60 s / 12.0 s spacing = 25 requests a minute.
    let config = microConfig(microConfigJson())
    check 5 * 60 div (DefaultTurnSpacingMs div 1000) <= 30
    check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
    # Both deadlines are WHOLE seconds: curly hands them to CURLOPT_TIMEOUT,
    # whose granularity is whole seconds and which therefore floors.
    check config.attempt1Ms mod 1000 == 0
    check config.retryMs mod 1000 == 0

  test "a directive is never empty on any tick after turn 0":
    var
      sim = newMicroSim(microConfigJson(maxTicks = 240))
      engine = initDecisionEngine(sim)
      ctl = initControlState(sim)
      prev = sim.idle()
    discard engine.turn(sim, 0, 12, 0)
    for tick in 0 ..< 120:
      ctl.observeEnemies(sim)
      var now = sim.idle()
      for seat in 0 ..< sim.config.friendlyCount():
        check engine.haveDirective[seat]
        let orders = engine.directives[seat].orders
        check orders.len == 1
        now[seat] = decodeInputMask(ctl.compileMask(sim, orders[0], seat))
      sim.step(now, prev)
      prev = now
      if sim.phase != Playing:
        break

  test "a disconnected seat keeps playing on the published baseline":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    let directive = engine.focusfireFor(sim, @[3])
    check directive.orders.len == 1
    check directive.orders[0].cogIndex == 3
    check directive.source == dsScripted

  test "the system prompt demands a reply beginning with a brace":
    check "MUST begin with '{'" in SystemPrompt
    check "target_id" in SystemPrompt
    check "focus|attack_move|kite|hold|screen|retreat|regroup" in SystemPrompt

  test "a reply naming no cog keeps last turn's directive, else focusfire's":
    ## Design §Reply schema, the `cogs` row. The reply PARSED, so this is a
    ## repair and not a fallback: the directive stays `llm`-sourced, which is
    ## what keeps it out of `sim.fallbackTurns` and out of the game log's
    ## "falling back" line.
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    let
      commanded = sim.commandedCogs(0)
      ids = @[sim.cogAlias(commanded[0])]
      empty = """{"note":"nothing to say","cogs":[]}"""
    ## Turn 0: nothing to carry on from, so it resolves to focusfire's order.
    var first = parseSquadDirective(
      extractJsonObject(empty), ids, commanded, 600, 330,
      MapWidth - 1, MapHeight - 1)
    engine.repairMissingOrders(sim, 0, first)
    let focus = engine.focusfireFor(sim, commanded)
    check first.orders.len == 1
    check first.orders[0].cogIndex == commanded[0]
    check first.orders[0].intent == focus.orders[0].intent
    check first.orders[0].targetId == focus.orders[0].targetId
    check first.orders[0].targetX == focus.orders[0].targetX
    check first.orders[0].targetY == focus.orders[0].targetY
    check first.source == dsLlm
    ## Turn k > 0: last turn's directive is what carries on.
    engine.directives[0] = SquadDirective(
      source: dsLlm, note: "hold the line",
      orders: @[CogOrder(cogIndex: commanded[0], id: ids[0], intent: intKite,
                         targetId: 7, targetX: 111, targetY: 222, say: "E7",
                         fromReply: true)])
    engine.haveDirective[0] = true
    var later = parseSquadDirective(
      extractJsonObject(empty), ids, commanded, 600, 330,
      MapWidth - 1, MapHeight - 1)
    engine.repairMissingOrders(sim, 0, later)
    check later.orders[0].intent == intKite
    check later.orders[0].targetId == 7
    check later.orders[0].targetX == 111
    check later.orders[0].targetY == 222
    check later.orders[0].say == "E7"
    check later.source == dsLlm
    ## The model's own note survives a repaired turn either way.
    check later.note == "nothing to say"

  test "only the terminal degrade line says \"falling back\"":
    ## Phase 60 greps the hosted GAME log for "falling back", so the phrase must
    ## mean a seat really did degrade to the scripted layer for a turn. An
    ## interim message for an attempt the retry may still rescue must not print
    ## it — a round whose retry landed had no degrade and must read that way.
    var printed = 0
    for line in readFile(GameDir / "src/smac/decide.nim").splitLines():
      let code = line.strip()
      if "falling back" notin code or code.startsWith("#"):
        continue
      inc printed
      check "falling back to focusfire (" in code
    check printed == 2
