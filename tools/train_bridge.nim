## Text decisions over complete native five-seat, three-battle episodes.
import std/[json, os, strutils]
import bitworld/spriteprotocol
import smac/[sim, control, directives, decide, llm, prompts]

const OperatorPrompt = "Coordinate your unit using only its battle view."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value: hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc action(directive: SquadDirective, sim: SimServer, seat, turn: int): JsonNode =
  let record = directive.directiveRecord(sim.gameIndex + 1, turn, seat,
    sim.aliasOfCog(seat), roleText(sim.config.roleOfCog(seat)))
  %*{"note": record["note"], "cogs": record["cogs"]}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: smac-train-bridge MANIFEST VARIANT", 1)
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == args[1]: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant"
  var
    game: SimServer
    engine: DecisionEngine
    previous: seq[InputState]
    views: seq[string]
    pending: seq[SquadDirective]
    seat, id, battles, turn: int
    lastTurnKey = -1
    ready = false
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    let kind = request["kind"].getStr()
    if kind == "reset":
      doAssert request["players"].getInt() == 5
      let selection = promptSelection(request)
      let split = request{"split"}.getStr("train")
      if split notin ["train", "validation", "test"]: raise newException(ValueError, "unknown split")
      if split == "train" and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        raise newException(ValueError, "held-out wording cannot enter training")
      var config = defaultGameConfig()
      let runtime = copy(variantConfig)
      runtime["seed"] = %seedOf(request["seed"].getStr())
      runtime["tokens"] = newJArray()
      for index in 0 ..< 5: runtime["tokens"].add(%("t" & $index))
      config.update($runtime)
      game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      engine = initDecisionEngine(game)
      engine.promptSelection = selection
      previous = @[]
      pending = @[]
      seat = 0
      id = 0
      battles = 0
      lastTurnKey = -1
      ready = false
    elif kind == "teacher":
      doAssert ready
      let teacher = engine.focusfireFor(game, game.commandedCogs(seat))
      response = %*{"response": $action(teacher, game, seat, turn)}
    elif kind == "step":
      doAssert ready and request["decision_id"].getInt() == id
      var cx, cy, count: int
      for index in game.config.friendlyCount() ..< game.players.len:
        if game.players[index].alive:
          cx += game.players[index].x + CollisionW div 2
          cy += game.players[index].y + CollisionH div 2
          inc count
      if count == 0:
        cx = MapWidth div 2
        cy = MapHeight div 2
      else:
        cx = cx div count
        cy = cy div count
      var directive = parseSquadDirective(extractJsonObject(request["response"].getStr()),
        @[game.cogAlias(seat)], @[seat], cx, cy, MapWidth - 1, MapHeight - 1)
      engine.repairMissingOrders(game, seat, directive)
      pending.add(directive)
      response = %*{"kind": "accepted", "action": action(directive, game, seat, turn)}
      inc seat
      inc id
      if seat == game.config.numAgents:
        for index, selected in pending:
          engine.directives[index] = selected
          engine.haveDirective[index] = true
        engine.snapshotTurn(game)
        for selected in pending:
          for order in selected.orders:
            if order.say.len > 0: discard game.applyShout(order.cogIndex, order.say)
        pending = @[]
        seat = 0
        ready = false
    else:
      raise newException(ValueError, "unknown request kind")

    if kind != "teacher":
      while not ready and battles < game.config.maxGames:
        if game.phase == Lobby and game.players.len == 0:
          for index in 0 ..< game.config.numAgents:
            let name = "policy-" & $index
            discard game.addPlayer(name, index, "", trusted = true)
            game.seatNames[index] = name
          for index in game.config.numAgents ..< game.config.microUnitCount():
            discard game.addPlayer(game.aliasOfCog(index), index, "", trusted = true)
          previous = newSeq[InputState](game.players.len)
        var inputs = newSeq[InputState](game.players.len)
        if game.phase == Playing:
          engine.ctl.observeEnemies(game)
          turn = game.gameTicksElapsed() div game.config.turnTicks
          let turnKey = game.gameIndex * 1_000_000 + turn
          if game.gameTicksElapsed() mod game.config.turnTicks == 0 and turnKey != lastTurnKey:
            lastTurnKey = turnKey
            views = @[]
            for index in 0 ..< game.config.numAgents:
              views.add(engine.seatViewJson(game, index, turn, game.config.maxTicks div game.config.turnTicks))
            ready = true
            break
          for index in 0 ..< game.config.numAgents:
            if engine.haveDirective[index]:
              inputs[index] = decodeInputMask(engine.ctl.compileMask(game,
                engine.directives[index].orders[0], index))
        let before = game.phase
        game.step(inputs, previous)
        previous = inputs
        if before != GameOver and game.phase == GameOver:
          inc battles
          game.archiveBattle()
          game.advanceBattle()
      var next: JsonNode
      if battles == game.config.maxGames:
        let outcome = parseJson(game.microResultsJson())
        doAssert outcome["reason"].getStr() == ReasonComplete
        var scores = newJObject()
        for index in 0 ..< game.config.numAgents: scores[$index] = outcome["scores"][index]
        next = %*{"kind": "terminal", "scores": scores}
      else:
        let system = systemPrompt(engine.promptSelection)
        let user = userMessage(OperatorPrompt, views[seat])
        let view = parseJson(views[seat])
        view["prompt_template"] = promptMetadata(engine.promptSelection, system, user)
        next = %*{"kind": "decision", "game": "smac-starcraft-micro", "decision_id": id,
          "seat": seat, "engine_seat": seat, "turn": turn, "semantic_view": view,
          "inbox": [], "speech_messages": [],
          "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
          "action_schema": {"type": "object", "required": ["cogs"], "properties": {
            "note": {"type": "string"}, "cogs": {"type": "array", "minItems": 1, "maxItems": 1,
              "items": {"type": "object", "required": ["id", "intent"], "properties": {
                "id": {"const": game.cogAlias(seat)}, "intent": {"enum": ["focus", "attack_move",
                  "kite", "hold", "screen", "retreat", "regroup"]}}}}}},
          "typed_question": newJNull(), "inference_mode": "text_action"}
      if kind == "step": response["observation"] = next
      else: response = next
    stdout.writeLine($response)
    stdout.flushFile()
