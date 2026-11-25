## The order schema: strict parsing, validation, and rune-boundary caps.
##
## An order is what a policy (LLM or scripted) issues once every five seconds.
## The control layer (`control.nim`) turns it into 120 ticks of quantised
## control bytes. Invalid orders are rejected rather than repaired into a
## different move; after exhausting retries the episode ends as a policy failure.
##
## Every string that can reach the replay is truncated on RUNE boundaries.
## A byte-truncated multi-byte character renders fine in a browser and then
## fails a strict JSON parser — that is the bug this cap exists to prevent.

import std/[json, strutils, unicode]
import types, rules, crates

const
  TargetMinX* = 8
  TargetMaxX* = MapWidth - 8
  TargetMinY* = 8
  TargetMaxY* = MapHeight - 8

proc clip*(text: string, limit: int): string =
  ## Rune-boundary truncation. `runeSubStr` walks codepoints, so the result
  ## is always valid UTF-8 even when rune `limit` is a 4-byte emoji.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit)

proc oneLine*(text: string): string =
  text.replace("\n", " ").replace("\r", " ").replace("\t", " ")

proc clampTarget*(x, y: int): Point =
  Point(x: clampInt(x, TargetMinX, TargetMaxX),
        y: clampInt(y, TargetMinY, TargetMaxY))

proc parseIntentText*(text: string): (Intent, bool) =
  for intent in Intent:
    if $intent == text:
      return (intent, true)
  (inWait, false)

proc parseAimText*(text: string): (AimMode, bool) =
  for aim in AimMode:
    if $aim == text:
      return (aim, true)
  (amTarget, false)

proc parseOrder*(payload: JsonNode, role: Role, at: Point,
                 crateList: seq[Crate]): Order =
  ## Strict order parse and legality check. Raises `LanternError` on any
  ## invalid field, wrong-role intent, or illegal crate reference.
  if payload.isNil or payload.kind != JObject:
    raise newException(LanternError, "order is not a JSON object")
  let intentNode = payload{"intent"}
  if intentNode.isNil or intentNode.kind != JString:
    raise newException(LanternError, "order carries no intent")
  let (intent, known) = parseIntentText(intentNode.getStr())
  if not known:
    raise newException(LanternError,
      "unknown intent: " & clip(intentNode.getStr(), 32))
  if not legalFor(intent, role):
    raise newException(LanternError,
      "intent " & $intent & " is not legal for " & $role)

  result = Order(intent: intent, target: clampTarget(at.x, at.y), crate: -1,
                 aim: amTarget, crawl: false, note: "", say: "")

  let targetNode = payload{"target"}
  if not targetNode.isNil and targetNode.kind != JNull:
    if targetNode.kind != JArray or targetNode.len != 2 or
        targetNode[0].kind != JInt or targetNode[1].kind != JInt:
      raise newException(LanternError, "target must be [int, int]")
    result.target = clampTarget(targetNode[0].getInt(), targetNode[1].getInt())

  let crateNode = payload{"crate"}
  if needsCrate(intent):
    if crateNode.isNil or crateNode.kind != JString:
      raise newException(LanternError,
        "intent " & $intent & " requires a canonical crate id")
    let index = parseCrateId(crateNode.getStr(), crateList.len)
    if index < 0:
      raise newException(LanternError,
        "unknown crate id: " & clip(crateNode.getStr(), MaxCrateIdRunes))
    let want =
      case intent
      of inPush, inLock: {csLoose}
      else: {csLocked}
    if crateList[index].state notin want:
      raise newException(LanternError,
        "crate " & crateId(index) & " is not legal for " & $intent)
    result.crate = index
  elif not crateNode.isNil and crateNode.kind != JNull:
    raise newException(LanternError,
      "crate must be null for intent " & $intent)

  let aimNode = payload{"aim"}
  if not aimNode.isNil and aimNode.kind != JNull:
    if aimNode.kind != JString:
      raise newException(LanternError, "aim must be a string")
    let (aim, aimKnown) = parseAimText(aimNode.getStr())
    if not aimKnown:
      raise newException(LanternError,
        "unknown aim: " & clip(aimNode.getStr(), 32))
    result.aim = aim

  let crawlNode = payload{"crawl"}
  if not crawlNode.isNil and crawlNode.kind != JNull:
    if crawlNode.kind != JBool:
      raise newException(LanternError, "crawl must be a boolean")
    let crawl = crawlNode.getBool()
    if role == roSeeker and crawl:
      raise newException(LanternError, "seekers cannot crawl")
    result.crawl = crawl

  let noteNode = payload{"note"}
  if not noteNode.isNil and noteNode.kind != JNull:
    if noteNode.kind != JString:
      raise newException(LanternError, "note must be a string")
    result.note = clip(oneLine(noteNode.getStr()), MaxNoteRunes)

  let sayNode = payload{"say"}
  if not sayNode.isNil and sayNode.kind != JNull:
    if sayNode.kind != JString:
      raise newException(LanternError, "say must be a string")
    result.say = clip(oneLine(sayNode.getStr()), MaxSayRunes)

proc unwrapSingleJsonFence*(text: string): string =
  ## Accepts either a bare JSON object or a single Markdown presentation fence
  ## (``` or ```json) wrapping a single JSON object, with no prose outside it.
  let trimmed = text.strip()
  if not trimmed.startsWith("```"):
    return trimmed
  let firstNewline = trimmed.find('\n')
  if firstNewline < 0:
    return ""
  let info = trimmed[3 ..< firstNewline].strip().toLowerAscii()
  if info.len > 0 and info != "json":
    return ""
  if not trimmed.endsWith("```"):
    return ""
  let closingStart = trimmed.len - 3
  if closingStart <= firstNewline:
    return ""
  let inner = trimmed[firstNewline + 1 ..< closingStart].strip()
  if "```" in inner:
    return ""
  inner

proc parseOrderText*(text: string, role: Role, at: Point,
                     crateList: seq[Crate]): Order =
  let trimmed = unwrapSingleJsonFence(text)
  if trimmed.len == 0 or trimmed[0] != '{':
    raise newException(LanternError, "reply must be a single JSON object")
  let payload =
    try: parseJson(trimmed)
    except CatchableError as error:
      raise newException(LanternError, "invalid JSON order: " & error.msg)
  parseOrder(payload, role, at, crateList)

proc orderJson*(order: Order): JsonNode =
  %*{"intent": $order.intent,
     "target": [order.target.x, order.target.y],
     "crate": (if order.crate < 0: newJNull() else: %crateId(order.crate)),
     "aim": $order.aim, "crawl": order.crawl,
     "note": order.note, "say": order.say}

proc orderCrateId*(order: Order): string =
  if order.crate < 0: "" else: crateId(order.crate)
