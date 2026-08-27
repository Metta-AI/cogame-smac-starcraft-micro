## The manifest: every invariant a platform rejection has ever taught us.
import std/[json, os, sets, strutils, unittest]
import smac_helpers

const
  SeatArrays = ["names", "scores", "win", "role", "alias", "damageDealt",
                "damageTaken", "kills", "deaths", "shots", "llmTurns",
                "fallbackTurns"]
  BattleArrays = ["battleResults", "battleTicks", "battleDamagePct",
                  "battleLossPct"]

proc manifest(): JsonNode =
  parseJson(readFile(GameDir / "coworld_manifest_template.json"))

suite "manifest":
  test "num_agents is 5 in every variant AND in the certification fixture":
    let m = manifest()
    check m["variants"].len == 4
    for variant in m["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 5
      # `num_agents` belongs INSIDE game_config, never at the variant's top
      # level: CoworldVariant is additionalProperties:false and rejects it
      # (cogame-goofspiel-oshi-zumo 0.1.0).
      check not variant.hasKey("num_agents")
      check variant.hasKey("description")
      check variant["description"].getStr().len > 0
    check m["certification"]["game_config"]["num_agents"].getInt() == 5
    check m["certification"]["players"].len == 5
    check m["certification"]["game_config"]["players"].len == 5

  test "no game_config carries a literal tokens array, and the schema wants it":
    let m = manifest()
    for variant in m["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not m["certification"]["game_config"].hasKey("tokens")
    # The runner INJECTS them (cogame-knights-archers 0.1.0), so the schema
    # still REQUIRES them and both halves are asserted here.
    check "tokens" in m["game"]["config_schema"]["required"].to(seq[string])

  test "every array property in config_schema declares minItems and maxItems":
    let m = manifest()
    for name, prop in m["game"]["config_schema"]["properties"]:
      if prop{"type"}.getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "results_schema keys equal the keys microResultsJson writes":
    var sim = newMicroSim()
    let
      m = manifest()
      written = parseJson(sim.microResultsJson())
    var declared, actual: HashSet[string]
    for key, _ in m["game"]["results_schema"]["properties"]:
      declared.incl(key)
    for key, _ in written:
      actual.incl(key)
    check declared == actual
    check declared.len == 26
    check m["game"]["results_schema"]["additionalProperties"].getBool() == false
    for name in SeatArrays:
      let prop = m["game"]["results_schema"]["properties"][name]
      check prop["minItems"].getInt() == 5
      check prop["maxItems"].getInt() == 5
      check written[name].len == 5
    for name in BattleArrays:
      let prop = m["game"]["results_schema"]["properties"][name]
      check prop["minItems"].getInt() == 1
      check prop["maxItems"].getInt() == 6

  test "protocols and docs are TEXT objects, and none of them is empty":
    let m = manifest()
    for key in ["player", "global"]:
      let node = m["game"]["protocols"][key]
      check node["type"].getStr() == "text"
      check node["value"].getStr().len > 0
    check m["game"]["docs"]["readme"]["type"].getStr() == "text"
    check m["game"]["docs"]["readme"]["value"].getStr().len > 0
    check m["game"]["docs"]["pages"].len == 4
    var ids: HashSet[string]
    for page in m["game"]["docs"]["pages"]:
      ids.incl(page["id"].getStr())
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 0
    check ids == ["rules", "scenarios", "protocol", "commanding"].toHashSet()

  test "the platform's own shape rules":
    let m = manifest()
    check m["game"]["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check m["episode_timeout_minutes"].getInt() == 20
    check m["tags"].len >= 3
    check m["game"].hasKey("description")
    check m["game"]["description"].getStr().len > 0
    check not m["game"].hasKey("tags")       # tags are top-level ONLY
    check not m.hasKey("replay_viewer")
    check not m.hasKey("version")
    check not m["game"].hasKey("display_name")
    check m["game"].hasKey("owner")
    check m["game"]["runnable"]["type"].getStr() == "game"
    check m["player"].len == 1
    check m["player"][0]["resources"]["limits"]["cpu"].getStr() == "1"

  test "the image placeholder derives from the compose service name":
    let m = manifest()
    let compose = readFile(GameDir / "compose.yaml")
    check "smac_starcraft_micro:" in compose
    check "coworld-smac-starcraft-micro:latest" in compose
    check m["game"]["runnable"]["image"].getStr() ==
      "{{SMAC_STARCRAFT_MICRO_IMAGE}}"
    check m["player"][0]["image"].getStr() == "{{SMAC_STARCRAFT_MICRO_IMAGE}}"

  test "game.name equals the secret namespace":
    let m = manifest()
    let name = m["game"]["name"].getStr()
    check name == "smac-starcraft-micro"
    check m["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & name & "/anthropic_api_key"

  test "every variant's wallClockBudgetSeconds fits inside 60% of 1200 s":
    let m = manifest()
    for variant in m["variants"]:
      check variant["game_config"]["wallClockBudgetSeconds"].getInt() <= 720
    check m["certification"]["game_config"]["wallClockBudgetSeconds"].getInt() <= 720

  test "EVERY variant's game_config actually constructs and steps a sim":
    # The collab-cooking 0.1.1 scar: test EVERY variant, not just the fixture —
    # here that means the 25-unit `corridor` roster is built and stepped.
    let m = manifest()
    for variant in m["variants"]:
      var gc = variant["game_config"].copy()
      var tokens = newJArray()
      for i in 0 ..< gc["num_agents"].getInt():
        tokens.add(%("t" & $i))
      gc["tokens"] = tokens
      gc["startWaitTicks"] = %0
      gc["maxTicks"] = %48
      gc["maxGames"] = %1
      var sim = newMicroSim($gc)
      check sim.players.len ==
        gc["num_agents"].getInt() + gc["enemyRoles"].len
      sim.stepIdle(24)
      sim.checkMicroInvariants()

  test "the certification fixture is the one the smoke script reads":
    let m = manifest()
    let gc = m["certification"]["game_config"]
    check gc["maxTicks"].getInt() == 480
    check gc["turnSpacingMs"].getInt() == 0
    check gc["friendlySpawnX"].getInt() == 470
    check gc["enemySpawnX"].getInt() == 760
    check gc["maxGames"].getInt() == 3
    # docker_smoke.sh cross-checks SMOKE_SEATS against this number.
    check "5" in readFile(GameDir / "tools" / "ci" / "docker_smoke.sh")
