## Export complete micro-combat episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import smac/[sim, roster, units, control, directives, decide, llm, prompts, evidence]

const OperatorPrompt = "Coordinate your unit using only its battle view."
const Variants = ["default", "outnumbered", "corridor", "heavy"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "default"
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    var engine = initDecisionEngine(sim)
    engine.promptSelection = selection
    let family = "smac-starcraft-micro-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var
      previous: seq[InputState]
      rows = newJArray()
      latest = newSeq[int](config.numAgents)
      battles = 0
      lastTurnKey = -1
    while battles < config.maxGames:
      if sim.phase == Lobby and sim.players.len == 0:
        for seat in 0 ..< config.numAgents:
          let name = "policy-" & $seat
          discard sim.addPlayer(name, seat, "", trusted = true)
          sim.seatNames[seat] = name
        for index in config.numAgents ..< config.microUnitCount():
          discard sim.addPlayer(sim.aliasOfCog(index), index, "", trusted = true)
        previous = newSeq[InputState](sim.players.len)
      var inputs = newSeq[InputState](sim.players.len)
      if sim.phase == Playing:
        engine.ctl.observeEnemies(sim)
        let
          turn = sim.gameTicksElapsed() div config.turnTicks
          turnKey = sim.gameIndex * 1_000_000 + turn
          turnsPerBattle = config.maxTicks div config.turnTicks
        if sim.gameTicksElapsed() mod config.turnTicks == 0 and
            turnKey != lastTurnKey:
          lastTurnKey = turnKey
          var views = newSeq[string](config.numAgents)
          for seat in 0 ..< config.numAgents:
            views[seat] = engine.seatViewJson(sim, seat, turn, turnsPerBattle)
          for seat in 0 ..< config.numAgents:
            let view = views[seat]
            let teacher = engine.focusfireFor(sim, sim.commandedCogs(seat))
            let record = teacher.directiveRecord(sim.gameIndex + 1, turn, seat,
              sim.aliasOfCog(seat), roleText(config.roleOfCog(seat)))
            let completion = %*{"note": record["note"],
              "cogs": record["cogs"]}
            let parsed = parseSquadDirective(completion,
              @[sim.cogAlias(seat)], @[seat], 0, 0,
              MapWidth - 1, MapHeight - 1)
            doAssert parsed.orders.len == 1
            doAssert parsed.orders[0].fromReply
            doAssert parsed.directiveRecord(sim.gameIndex + 1, turn, seat,
              sim.aliasOfCog(seat), roleText(config.roleOfCog(seat)))["cogs"] ==
              completion["cogs"]
            engine.directives[seat] = parsed
            engine.haveDirective[seat] = true
            let installed = engine.directives[seat].directiveRecord(sim.gameIndex + 1, turn, seat,
              sim.aliasOfCog(seat), roleText(config.roleOfCog(seat)))
            let executed = %*{"note": installed["note"], "cogs": installed["cogs"]}
            let system = systemPrompt(selection)
            let user = userMessage(OperatorPrompt, view)
            let observation = parseJson(view)
            observation["prompt_template"] = promptMetadata(selection, system, user)
            let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
            let attemptId = $rows.len & "-teacher"
            latest[seat] = rows.len
            rows.add(%*{
              "schema_version": "1", "event_type": "decision", "episode_id": episode,
              "decision_id": $rows.len, "decision_index": rows.len,
              "game": "smac-starcraft-micro", "game_version": "source-" & sourceRevision,
              "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
              "observation": observation, "prompt": messages,
              "attempts": [{"attempt_id": attemptId, "policy": "scripted-focusfire",
                "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
                "response": $completion, "parsed_action": executed, "accepted": true,
                "request": newJNull(), "platform_call_id": newJNull(),
                "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
              "selected_attempt_id": attemptId, "executed_action": executed,
              "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
          engine.snapshotTurn(sim)
          for seat in 0 ..< config.numAgents:
            for order in engine.directives[seat].orders:
              if order.say.len > 0:
                discard sim.applyShout(order.cogIndex, order.say)
        for seat in 0 ..< config.numAgents:
          if engine.haveDirective[seat]:
            let mask = engine.ctl.compileMask(sim,
              engine.directives[seat].orders[0], seat)
            inputs[seat] = decodeInputMask(mask)
      let before = sim.phase
      sim.step(inputs, previous)
      previous = inputs
      if before != GameOver and sim.phase == GameOver:
        inc battles
        sim.archiveBattle()
        sim.advanceBattle()
    let outcome = parseJson(sim.microResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete
    doAssert outcome["games"].getInt() == config.maxGames
    doAssert rows.len > 0
    for seat in 0 ..< config.numAgents: rows[latest[seat]]["terminal"] = %true
    for row in rows: stream.writeLine($row)
    var participants = newJObject()
    for seat in 0 ..< config.numAgents: participants[$seat] = %*{"score": outcome["scores"][seat]}
    stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "smac-starcraft-micro", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed", "outcome": outcome,
      "participant_outcomes": participants}))
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": outcome["teamScore"], "wins": outcome["battlesWon"]})
  stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "smac-starcraft-micro",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-focusfire",
    "operator_prompt": OperatorPrompt,
    "prompt_configuration": selectionMetadata(selection),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", episodes
