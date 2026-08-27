## Tolerant parsing and repair, including the 4-byte-emoji rune boundary.
import std/[json, unicode, unittest]
import smac_helpers

const
  Ids = @["RANGER-alpha"]
  Cogs = @[0]

proc parse(text: string): SquadDirective =
  parseSquadDirective(extractJsonObject(text), Ids, Cogs, 600, 330,
                      MapWidth - 1, MapHeight - 1)

suite "directives":
  test "prose-prefixed and fenced JSON both parse":
    check parse("Sure! Here you go:\n```json\n" &
      """{"note":"go","cogs":[{"id":"RANGER-alpha","intent":"focus",""" &
      """"target_id":3,"target":[10,10],"say":"E3"}]}""" & "\n```").
      orders[0].targetId == 3
    check parse("""thinking... {"note":"n","cogs":[{"id":"RANGER-alpha"}]}""").
      orders[0].fromReply

  test "cogs as an id-keyed object is accepted":
    let d = parse("""{"cogs":{"RANGER-alpha":{"intent":"kite","target_id":2}}}""")
    check d.orders[0].intent == intKite
    check d.orders[0].targetId == 2

  test "unknown and hyphenated intents normalise":
    check parse("""{"cogs":[{"id":"RANGER-alpha","intent":"ATTACK-MOVE"}]}""").
      orders[0].intent == intAttackMove
    check parse("""{"cogs":[{"id":"RANGER-alpha","intent":"nonsense"}]}""").
      orders[0].intent == intFocus

  test "target_id accepts E3, e3, a numeric string and a float":
    check readTargetId(%"E3") == 3
    check readTargetId(%"e3") == 3
    check readTargetId(%"7") == 7
    check readTargetId(%3.0) == 3
    check readTargetId(newJNull()) == -1
    check readTargetId(%"nonsense") == -1

  test "an off-map target is clamped and a missing one takes the default":
    let far = parse("""{"cogs":[{"id":"RANGER-alpha","target":[99999,-4]}]}""")
    check far.orders[0].targetX == MapWidth - 1
    check far.orders[0].targetY == 0
    let none = parse("""{"cogs":[{"id":"RANGER-alpha"}]}""")
    check none.orders[0].targetX == 600
    check none.orders[0].targetY == 330

  test "three cogs keep the first, an id from another seat lands by position":
    let many = parse("""{"cogs":[{"id":"RANGER-alpha"},{"id":"BLADE-alpha"},""" &
      """{"id":"BLADE-beta"}]}""")
    check many.orders.len == 1
    let other = parse("""{"cogs":[{"id":"BLADE-gamma","intent":"hold"}]}""")
    check other.orders.len == 1
    check other.orders[0].id == "RANGER-alpha"
    check other.orders[0].intent == intHold

  test "a runaway cogs[].id is capped on a rune boundary, at 16":
    ## MaxCogIdRunes is now applied where it means something: `cogs[].id` is
    ## the one unbounded MODEL-authored string the matcher reads, and it reads
    ## it with `endsWith` both ways. The cut is on a rune boundary, so a 4-byte
    ## emoji at the cap cannot be split in half.
    check MaxCogIdRunes == 16
    check "RANGER-epsilon".runeLen <= MaxCogIdRunes
    let runaway = parse(
      "{\"cogs\":[{\"id\":\"RANGER-alpha" & "\u{1F600}".repeat(40) &
      "\",\"intent\":\"kite\"}]}")
    check runaway.orders.len == 1
    check runaway.orders[0].id == "RANGER-alpha"
    check runaway.orders[0].intent == intKite
    # And 16 is not a cap that CUTS a real id: the longest alias this game
    # issues is 14 runes, and it has to keep matching BY NAME — a shorter cap
    # would fall through to positional assignment and hand each cog the other's
    # order.
    let pair = parseSquadDirective(
      extractJsonObject(
        "{\"cogs\":[{\"id\":\"RANGER-epsilon\",\"intent\":\"hold\"}," &
        "{\"id\":\"BLADE-alpha\",\"intent\":\"kite\"}]}"),
      @["BLADE-alpha", "RANGER-epsilon"], @[2, 4],
      600, 330, MapWidth - 1, MapHeight - 1)
    check pair.orders[0].intent == intKite
    check pair.orders[1].intent == intHold

  test "zero cogs raises, which is what the retry exists for":
    expect DirectiveError:
      discard parse("""{"note":"nothing to say","cogs":[]}""")
    expect DirectiveError:
      discard parse("no json at all here")

  test "a 300-character note is cut to 160 runes":
    var long = ""
    for _ in 0 ..< 300:
      long.add('x')
    let d = parse("""{"note":"""" & long & """","cogs":[{"id":"RANGER-alpha"}]}""")
    check d.note.runeLen == MaxNoteRunes

  test "a say whose 10th and 11th characters are a 4-byte emoji cuts on a rune":
    # The cut MUST land on a rune boundary: a byte-truncated multi-byte
    # character renders in a browser and then fails a strict UTF-8 parser.
    let say = "abcdefghi\u{1F600}\u{1F600}"
    check say.runeLen == 11
    let cut = say.truncateRunes(MaxSayRunes)
    check cut.runeLen == MaxSayRunes
    check cut.validateUtf8() == -1
    # The sanitiser drops the non-ASCII runes but never leaves half of one.
    let sanitized = sanitizeSay(say)
    check sanitized.validateUtf8() == -1
    check sanitized.runeLen <= MaxSayRunes
    # And it still round-trips through the JSON the replay actually carries.
    let record = $(%*{"say": cut})
    check parseJson(record)["say"].getStr() == cut

  test "the serialized directive record stays inside MaxDirectiveRunes":
    var directive = SquadDirective(source: dsLlm)
    var long = ""
    for _ in 0 ..< 400:
      long.add("\u{1F600}")
    directive.note = long
    directive.orders = @[CogOrder(cogIndex: 0, id: "RANGER-alpha",
                                  intent: intFocus, targetId: 3,
                                  targetX: 10, targetY: 10, say: "E3")]
    let record = directive.boundedDirectiveRecord(1, 0, 0, "RANGER-alpha", "ranger")
    check record.runeLen <= MaxDirectiveRunes
    check record.validateUtf8() == -1
    check parseJson(record)["k"].getStr() == "directive"
