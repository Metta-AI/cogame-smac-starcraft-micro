## Export complete micro-combat episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import smac/[sim, roster, units, control, directives, decide, llm]

const OperatorPrompt = "Coordinate your unit using only its battle view."
const Variants = ["default", "outnumbered", "corridor", "heavy"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    var engine = initDecisionEngine(sim)
    var
      previous: seq[InputState]
      rows: seq[string]
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
          for seat in 0 ..< config.numAgents:
            let view = engine.seatViewJson(sim, seat, turn, turnsPerBattle)
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
            rows.add($(%*{
              "episode_id": "smac-starcraft-micro-" & variant & "-" & $seed,
              "seed": "smac-starcraft-micro-" & variant & "-" & $seed,
              "decision_id": (sim.gameIndex * 1000 + turn) *
                config.numAgents + seat,
              "prompt": [
                {"role": "system", "content": SystemPrompt},
                {"role": "user", "content": userMessage(OperatorPrompt, view)}
              ],
              "completion": [{"role": "assistant", "content": $completion}],
              "game": "smac-starcraft-micro",
              "action_schema_revision": "micro-directive-v1"
            }))
            engine.directives[seat] = parsed
            engine.haveDirective[seat] = true
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
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": outcome["teamScore"], "wins": outcome["battlesWon"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "smac-starcraft-micro",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-focusfire",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
