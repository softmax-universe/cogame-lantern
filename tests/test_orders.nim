## Strict order parsing, legality validation, and RUNE-boundary caps.
##
## A byte-truncated multi-byte character renders fine in a browser and then
## fails a strict JSON parser: that is the bug these caps exist to prevent, so
## the emoji case here is the point of the file, not a curiosity.

import std/[json, strutils, unicode, unittest]
import support/helpers

let crateList = block:
  var list: seq[Crate]
  for index in 0 ..< 10:
    list.add(Crate(c: Point(x: 100 + 60 * index, y: 300), state: csLoose))
  list[3].state = csLocked
  list

const Here = Point(x: 600, y: 300)

proc hider(text: string): Order =
  parseOrderText(text, roHider, Here, crateList)

proc seeker(text: string): Order =
  parseOrderText(text, roSeeker, Here, crateList)

suite "strict parsing":
  test "plain JSON":
    let order = hider("""{"intent":"hide","target":[200,200],"crawl":true}""")
    check order.intent == inHide
    check order.target == Point(x: 200, y: 200)
    check order.crawl

  test "single markdown JSON presentation fence is accepted without inventing actions":
    let fencedJson = hider("```json\n{\"intent\":\"wait\"}\n```")
    check fencedJson.intent == inWait
    check fencedJson.target == Here
    let fencedPlain = hider("```\n{\"intent\":\"hide\",\"target\":[200,200],\"crawl\":true}\n```")
    check fencedPlain.intent == inHide
    check fencedPlain.target == Point(x: 200, y: 200)
    check fencedPlain.crawl

  test "prose, non-json fences, and multiple fences are rejected":
    expect LanternError:
      discard hider("""Sure! Here is my order: {"intent":"scout","target":[300,300]}""")
    expect LanternError:
      discard hider("Sure!\n```json\n{\"intent\":\"wait\"}\n```")
    expect LanternError:
      discard hider("```json\n{\"intent\":\"wait\"}\n```\nThanks!")
    expect LanternError:
      discard hider("```python\n{\"intent\":\"wait\"}\n```")
    expect LanternError:
      discard hider("```json\n{\"intent\":\"wait\"}\n```\n```json\n{\"intent\":\"wait\"}\n```")
    expect LanternError:
      discard hider("""I considered } and then decided. {"intent":"flee","target":[10,10]}""")

  test "missing or unknown intent raises":
    expect LanternError:
      discard hider("I would rather not say.")
    expect LanternError:
      discard hider("""{"target":[10,10]}""")
    expect LanternError:
      discard hider("""{"intent":"teleport"}""")

suite "legality and strict field types":
  test "wrong-role intents are rejected rather than rewritten":
    expect LanternError:
      discard hider("""{"intent":"pry","crate":"C3"}""")
    expect LanternError:
      discard seeker("""{"intent":"lock","crate":"C1"}""")

  test "target requires [int, int] and clamps to map bounds":
    check hider("""{"intent":"hide","target":[-9000,9000]}""").target ==
      Point(x: TargetMinX, y: TargetMaxY)
    check hider("""{"intent":"hide"}""").target == Here
    check hider("""{"intent":"hide","target":null}""").target == Here
    expect LanternError:
      discard hider("""{"intent":"hide","target":["612","118"]}""")
    expect LanternError:
      discard hider("""{"intent":"hide","target":{"x":50,"y":60}}""")
    expect LanternError:
      discard hider("""{"intent":"hide","target":[612.0,118.7]}""")

  test "crate requires canonical C0..C9 in a legal state":
    check hider("""{"intent":"push","crate":"C4","target":[10,10]}""").crate == 4
    check seeker("""{"intent":"pry","crate":"C3"}""").crate == 3
    expect LanternError:
      discard hider("""{"intent":"push","crate":4,"target":[10,10]}""")
    expect LanternError:
      discard hider("""{"intent":"push","crate":"c4","target":[10,10]}""")
    expect LanternError:
      discard hider("""{"intent":"push","crate":"C42","target":[10,10]}""")
    expect LanternError:
      discard seeker("""{"intent":"pry","crate":"C0"}""")
    expect LanternError:
      discard hider("""{"intent":"push","crate":"C3","target":[10,10]}""")
    expect LanternError:
      discard hider("""{"intent":"hide","crate":"C0"}""")

  test "aim and crawl require canonical types and role legality":
    check seeker("""{"intent":"sweep","aim":"sweep","crawl":false}""").aim == amSweep
    expect LanternError:
      discard hider("""{"intent":"hide","aim":"spin"}""")
    expect LanternError:
      discard seeker("""{"intent":"sweep","crawl":true}""")
    expect LanternError:
      discard hider("""{"intent":"hide","crawl":"true"}""")
    expect LanternError:
      discard hider("""{"intent":"hide","crawl":1}""")
    expect LanternError:
      discard hider("""{"intent":"hide","crawl":"maybe"}""")

suite "rune-boundary truncation":
  test "a 400-character note is cut to exactly 140 runes":
    let order = hider("""{"intent":"hide","note":"""" &
      "x".repeat(400) & """"}""")
    check order.note.runeLen == MaxNoteRunes

  test "a say whose 32nd and 33rd runes are 4-byte emoji cuts on the RUNE":
    ## 31 ASCII runes, then two 4-byte emoji. Rune 32 is the first emoji, so
    ## the cut must keep it whole and drop the second entirely.
    let say = "a".repeat(31) & "\u{1F526}\u{1F50E}"
    check say.runeLen == 33
    check say.len == 31 + 8            ## bytes, not runes
    let order = hider($ %*{"intent": "hide", "say": say})
    check order.say.runeLen == MaxSayRunes
    check order.say == "a".repeat(31) & "\u{1F526}"
    check validateUtf8(order.say) == -1
    ## and it survives a strict round trip through the replay encoder
    let encoded = $orderJson(order)
    check validateUtf8(encoded) == -1
    check parseJson(encoded)["say"].getStr() == order.say

  test "the caps hold for every string that reaches the replay":
    check clip("x".repeat(500), MaxDetailRunes).runeLen == MaxDetailRunes
    check clip("\u{1F526}".repeat(500), MaxPolicyRunes).runeLen ==
      MaxPolicyRunes
    check validateUtf8(clip("\u{1F526}".repeat(500), MaxPolicyRunes)) == -1

  test "a note with newlines becomes one line":
    check hider("""{"intent":"hide","note":"a\nb\tc"}""").note == "a b c"

suite "the two-failure ladder":
  test "unusable replies raise":
    var failures = 0
    for reply in ["", "no.", "{}", """{"intent":"fly"}""", "{\"intent\":"]:
      try:
        discard hider(reply)
      except CatchableError:
        inc failures
    check failures == 5
