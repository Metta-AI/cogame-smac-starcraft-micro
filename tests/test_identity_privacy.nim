## The two name spaces, asserted from BOTH sides.
import std/[json, strutils, unittest]
import smac_helpers

const Sentinel = "sentinel-policy-address"

suite "identity privacy":
  test "a seat's view, its shouts and its aliases never carry a policy name":
    var sim = newMicroSim()
    sim.players[0].address = Sentinel
    sim.seatNames[0] = Sentinel
    var engine = initDecisionEngine(sim)
    for seat in 0 ..< sim.config.friendlyCount():
      check Sentinel notin engine.seatViewJson(sim, seat, 0, 12)
    for i in 0 ..< sim.players.len:
      check Sentinel notin sim.cogAlias(i)
      check Sentinel notin sim.aliasOfCog(i)

  test "the system prompt and the user message never carry a policy name":
    var sim = newMicroSim()
    sim.seatNames[0] = Sentinel
    var engine = initDecisionEngine(sim)
    let user = userMessage("play well", engine.seatViewJson(sim, 0, 0, 12))
    check Sentinel notin user
    check Sentinel notin SystemPrompt
    # And the operator's own prompt is never echoed into a record.
    check "play well" in user

  test "the register record is redacted: label and kind, never the prompt":
    let record = registerRecord(
      0, "RANGER-alpha", "ranger", "marshal", "llm", "focusfire")
    check "marshal" in record
    check "RANGER-alpha" in record
    check Sentinel notin record
    let node = parseJson(record)
    check not node.hasKey("prompt")

  test "a directive record carries the alias and the role, never a name":
    var directive = SquadDirective(source: dsLlm, note: "everyone on E3")
    directive.orders = @[CogOrder(cogIndex: 0, id: "RANGER-alpha",
                                  intent: intFocus, targetId: 3, say: "E3")]
    let record = directive.boundedDirectiveRecord(
      1, 4, 0, "RANGER-alpha", "ranger")
    check Sentinel notin record
    check "RANGER-alpha" in record
    let node = parseJson(record)
    check node["alias"].getStr() == "RANGER-alpha"
    check node["role"].getStr() == "ranger"

  test "the SPECTATOR side MUST carry the real name":
    var sim = newMicroSim()
    sim.players[0].address = Sentinel
    sim.seatNames[0] = Sentinel
    # results.names is the spectator half of the two name spaces.
    let results = parseJson(sim.microResultsJson())
    check results["names"][0].getStr() == Sentinel
    check results["alias"][0].getStr() == "RANGER-alpha"
    check results["role"][0].getStr() == "ranger"
    # and so is the broadcast roster.
    let frame = parseJson(sim.buildStateJson(
      newJArray(), true, 1.0, sim.tickCount, false, true, -1, -1))
    var found = false
    for entry in frame["roster"]:
      if entry["name"].getStr() == Sentinel:
        found = true
        check entry["alias"].getStr() == "RANGER-alpha"
    check found
