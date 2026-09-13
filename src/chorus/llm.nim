## Claude-backed decision making for Chorus. Each seat's policy is just a
## prompt: the game server composes the seat's view (its voice, the whole
## grid, the chord plan, the live score, its own counterfactual credit, the
## other seats' messages, its notes) plus that seat's prompt and asks Claude
## which bar it writes.
##
## Decisions within a turn are simultaneous by rule, so all four requests go
## out as ONE parallel batch (curly.makeRequests); invalid replies are
## retried once as a smaller batch carrying an explicit hint, and anything
## still failing plays the `arpeggio` baseline, which is legal by
## construction.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing.

import
  std/[json, math, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## Any error text that could reach the replay is cut at this many runes.
  MaxErrorLen* = 200

type
  ScriptKind* = enum
    skNone = "none"
    skArpeggio = "arpeggio"
    skPedal = "pedal"

  Decision* = object
    target*: int
    steps*: seq[int]
    say*: string
    notes*: string      ## "" when the reply carried none
    scripted*: bool     ## true when a baseline produced this bar rather
                        ## than a parsed model reply — including the
                        ## fallback after the retry is exhausted. The
                        ## replay's `bar.scripted` flag is this field.

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock
                          ## picks from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"arpeggio" play the arpeggio
  ## bot, "pedal" the pedal bot, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "arpeggio": skArpeggio
  of "pedal", "drone": skPedal
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "chorus llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. The config "model" field is NOT consulted
  ## here: it applies to the direct-Anthropic transport only, and the
  ## haiku-first ordering below is a shared-capacity decision that trumps
  ## per-game preference.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "chorus llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "chorus llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "chorus llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "chorus llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc clampToken(token: int): int =
  max(0, min(MaxToken, token))

proc emptySteps(): seq[int] =
  result = newSeq[int](Steps)
  for index in 0 ..< Steps:
    result[index] = Rest

proc arpeggioBar*(sim: Sim, voice, bar: int): seq[int] =
  ## The strong baseline, and the fallback for a failed LLM seat: chord
  ## tones spread across the voices, rotated a step each bar so the piece
  ## never settles on the repetition floor.
  result = emptySteps()
  let root = sim.chords[bar]
  let tones = [clampToken(root), clampToken(root + 2), clampToken(root + 4)]
  let rot = bar mod 3
  var onsets: seq[int]
  var tokens: seq[int]
  case voice
  of 0:
    onsets = @[0, 8]
    tokens =
      if bar mod 2 == 0: @[tones[0], tones[0]]
      else: @[tones[0], tones[2]]
  of 1:
    onsets = @[0, 4, 8, 12]
    tokens = @[tones[0], tones[1], tones[2], tones[1]]
  of 2:
    onsets = @[2, 6, 10, 14]
    tokens = @[tones[1], tones[2], tones[0], tones[2]]
  else:
    onsets = @[0, 3, 6, 10, 12]
    tokens = @[tones[2], clampToken(tones[0] + 7), tones[1], tones[2],
      tones[1]]
  for index, step in onsets:
    result[step] = tokens[(index + rot) mod tokens.len]

proc pedalBar*(sim: Sim, voice, bar: int): seq[int] =
  ## The weak, honest filler: a root pedal on the downbeat and a fifth
  ## halfway through the odd bars. Too thin to sit in the density band, so
  ## a table of four pedals scores well below a table of four arpeggios.
  result = emptySteps()
  let root = sim.chords[bar]
  result[0] = clampToken(root)
  if bar mod 2 == 1:
    result[8] = clampToken(root + 4)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal; never talks or notes;
  ## always writes this turn's new bar.
  let voice = sim.voiceOf[seat]
  result.target = sim.turn
  result.scripted = true
  result.steps =
    case kind
    of skPedal: pedalBar(sim, voice, sim.turn)
    else: arpeggioBar(sim, voice, sim.turn)

# ---- Prompt building --------------------------------------------------------

proc seatName(sim: Sim, seat: int): string =
  sim.names[seat]

proc voiceLabel(sim: Sim, voice: int): string =
  ## "Gizmo (ALTO)".
  sim.seatName(sim.seatOf[voice]) & " (" & VoiceNames[voice].toUpperAscii() &
    ")"

proc one(value: float): string =
  formatFloat(value, ffDecimal, 1)

proc two(value: float): string =
  formatFloat(value, ffDecimal, 2)

proc signed(value: float): string =
  (if value >= 0.0: "+" else: "") & one(value)

proc chordDegrees(root: int): string =
  $root & ", " & $(root + 2) & ", " & $(root + 4)

proc chordPlanLine*(sim: Sim): string =
  var parts: seq[string]
  for bar, degree in sim.chords:
    parts.add("bar " & $bar & " " & chordName(degree))
  parts.join(" | ")

proc tokenCell(token: int): string =
  let text = if token < 0: "." else: $token
  align(text, 3)

proc gridBlock(sim: Sim, seat: int): string =
  ## Every bar written so far, all four voices, column-aligned oldest first.
  let ownVoice = sim.voiceOf[seat]
  var lines: seq[string]
  for bar in 0 .. sim.turn:
    var head = "bar " & $bar & "  " & chordName(sim.chords[bar])
    if bar == sim.turn:
      var hold = ""
      for step in 0 ..< Steps:
        hold.add(tokenCell(sim.grid[ownVoice][bar][step]))
      head.add("   (this turn — your voice currently holds:" & hold & ")")
    lines.add(head)
    for voice in 0 ..< Voices:
      var row = "  " & align(VoiceNames[voice].toUpperAscii() & "(" &
        sim.seatName(sim.seatOf[voice]) & ")", 22) & " "
      for step in 0 ..< Steps:
        row.add(tokenCell(sim.grid[voice][bar][step]))
      if voice == ownVoice:
        row.add("   <- YOU")
      lines.add(row)
  lines.join("\n")

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.seatName(seat)
  let voice = sim.voiceOf[seat]
  let voiceUp = VoiceNames[voice].toUpperAscii()
  var others: seq[string]
  for other in 0 ..< Voices:
    if other != voice:
      others.add(sim.voiceLabel(other))
  result.add("You are " & me & ", the " & voiceUp &
    " voice in a four-cog studio writing one piece of music together on a " &
    "16-step sequencer. The other voices are " & others.join(", ") &
    ". Each cog owns one voice; nobody else can write a note in yours and " &
    "you cannot write a note in theirs.\n\n")
  result.add("THE PIECE: " & $sim.config.bars & " bars of " & $Steps &
    " steps, key " & sim.keyName() & ", " & $sim.bpm &
    " BPM. Every step is one note or a rest, and a note lasts exactly one " &
    "step.\n\n")
  result.add("NOTATION: a bar is " & $Steps & " tokens. -1 is a rest. 0.." &
    $MaxToken & " are scale degrees: 0 is the tonic, 6 the seventh, 7 the " &
    "tonic an octave up, 13 the seventh two octaves up. Your voice sounds " &
    "in the " & voiceUp & " register (MIDI " & $sim.baseMidi(voice) & ".." &
    $(sim.baseMidi(voice) + 23) & ").\n\n")
  result.add("THE CHORD PLAN is fixed, shared and public: " &
    sim.chordPlanLine() & ". The chord tones of a chord rooted on degree r " &
    "are r, r+2 and r+4.\n\n")
  result.add("""EACH TURN every cog writes one bar, all four at the same time, and nobody
sees the others' choice until the turn resolves. You may WRITE the new bar
(target = this turn's index) or REWRITE one of your own earlier bars
(target < this turn's index); if you rewrite, your new bar automatically
holds a copy of your previous bar.

THE PIECE IS SCORED 0-100 by a fixed, public, deterministic metric:
CONSONANCE (35%) - the mean quality of every simultaneous interval between
two sounding voices; fifths, thirds and sixths score high, seconds,
sevenths and tritones score low, unisons and octaves 0.6.
VOICE LEADING (25%) - the mean quality of each voice's motion between its
consecutive notes; steps of 1-2 semitones score 1.0, leaps score less,
leaps over an octave score 0; parallel fifths and octaves cut this term.
RHYTHM (25%) - onsets on steps 0/4/8/12 score best, 2/6/10/14 next, odd
steps least; total note density should sit between 20% and 55% of the whole
grid; and the best steps are those where 1 to 3 voices sound, not 0 and not
4.
NOVELTY (15%) - each bar is compared with the same voice's earlier bars;
the target is that about HALF of a bar differs from the closest earlier
one. Pure repetition scores 0 and so does never repeating anything.

YOUR SCORE IS A COUNTERFACTUAL: the piece is scored once as written and
once with every note of YOUR voice deleted; your score is the difference.
Nothing else scores. There is no vote and nobody judges you. A voice that
is rougher than the piece's average, or that fills the grid until all four
voices sound at once, can score BELOW ZERO - deleting it would improve the
piece.
""")
  if sim.config.talk:
    result.add("\nEach turn you may SAY one short line (max " & $MaxSayLen &
      " characters) that all three other cogs read next turn. It is not " &
      "binding and may or may not be honest.\n")
  result.add("""
Your notes are private to you and fed back to you every turn. Use them to
keep track of your motif, what you have already used, and what you plan
next.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object.
Your reply must begin with the character { and end with }.""")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc heardBlock(sim: Sim, voice: int): string =
  if not sim.config.talk:
    return ""
  var lines: seq[string]
  for other in 0 ..< Voices:
    if other != voice and sim.heard[other].len > 0:
      lines.add(sim.voiceLabel(other) & " said: \"" & sim.heard[other] & "\"")
  "MESSAGES LAST TURN:\n" &
    (if lines.len > 0: lines.join("\n") else: "(none)") & "\n\n"

proc legalTargetList*(sim: Sim): string =
  var parts: seq[string]
  for target in sim.legalTargets():
    parts.add($target)
  parts.join(",")

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let voice = sim.voiceOf[seat]
  let voiceUp = VoiceNames[voice].toUpperAscii()
  let chord = sim.chords[sim.turn]
  result.add("Turn " & $sim.turn & " of " & $sim.config.bars &
    ". You are the " & voiceUp & ", seat " & sim.seatName(seat) & ".\n\n")
  result.add("CHORD PLAN: " & sim.chordPlanLine() & "  (this turn's bar " &
    $sim.turn & " is " & chordName(chord) & ": degrees " &
    chordDegrees(chord) & ")\n\n")
  result.add("THE PIECE SO FAR (all four voices; . = rest):\n" &
    sim.gridBlock(seat) & "\n\n")
  let parts = sim.pieceScore(sim.grid, sim.turnsPlayed)
  result.add("SCORE NOW: piece " & one(parts.piece) & " = consonance " &
    two(parts.consonance) & ", voice leading " & two(parts.leading) &
    ", rhythm " & two(parts.rhythm) & ", novelty " & two(parts.novelty) &
    ".\n\n")
  let without =
    sim.pieceScore(mutedGrid(sim.grid, voice), sim.turnsPlayed).piece
  result.add("YOUR COUNTERFACTUAL CREDIT NOW: " &
    signed(parts.piece - without) & " (the piece without your voice scores " &
    one(without) & ").\n\n")
  result.add(sim.heardBlock(voice))
  result.add("YOUR NOTES FROM EARLIER TURNS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("LEGAL TARGETS THIS TURN: " & sim.legalTargetList() &
    "  (bar " & $sim.turn & " is the new bar).\n\n")
  result.add("Reply with ONLY {\"target\": " & $sim.turn &
    ", \"steps\": [0,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1,-1]" &
    (if sim.config.talk: ", \"say\": \"…\"" else: "") &
    ", \"notes\": \"…\"} — steps is exactly " & $Steps &
    " values, each -1 (rest) or a whole number 0.." & $MaxToken &
    "; target is one of the legal targets above" &
    (if sim.config.talk: "; say at most " & $MaxSayLen & " characters (or \"\")"
     else: "") &
    "; notes at most " & $MaxNotesLen & " characters.")

proc retryHint*(sim: Sim, reason: string): string =
  "\nYour previous reply was invalid: " & reason &
    ". Respond with ONLY the requested JSON object, with \"steps\" exactly " &
    $Steps & " whole numbers each -1 or 0.." & $MaxToken &
    " and \"target\" one of " & sim.legalTargetList() & "."

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose after the closing brace.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(ChorusError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    ## Same effort guard as the direct transport: a pinned BEDROCK_MODEL on a
    ## Sonnet/Opus tier would otherwise run at the default (high) effort.
    let bedrockModel = client.bedrockModels[client.bedrockModel]
    if "haiku" notin bedrockModel and "4-5" notin bedrockModel:
      body["output_config"] = %*{"effort": "low"}
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a ChorusError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(ChorusError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(ChorusError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(ChorusError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(ChorusError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(ChorusError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(ChorusError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(ChorusError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte
  ## slice through a multi-byte character would leave invalid UTF-8 in the
  ## replay and break a strict JSON parser.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc parseStepToken(text: string): int =
  ## One token of a string-form `steps` field. ".", "-", "r", "R" and "rest"
  ## are all rests; anything else must be a number (floats are rounded).
  let raw = text.strip()
  if raw.len == 0:
    raise newException(ChorusError, "empty step token")
  case raw.toLowerAscii()
  of ".", "-", "r", "rest":
    return Rest
  else:
    discard
  try:
    return int(round(parseFloat(raw)))
  except ValueError:
    raise newException(ChorusError, "not a step token: " & raw)

proc parseSteps*(node: JsonNode): seq[int] =
  ## `steps` is normally a JSON array of 16 integers, but a model that has
  ## been asked for a formal structure will sometimes hand back a string, or
  ## an array of numeric strings, or floats. Normalising here — before
  ## validation — is what keeps the fallback rate down.
  if node.isNil or node.kind == JNull:
    raise newException(ChorusError, "no steps in response")
  var tokens: seq[string]
  case node.kind
  of JArray:
    for item in node:
      case item.kind
      of JInt: result.add(int(item.getInt()))
      of JFloat: result.add(int(round(item.getFloat())))
      of JString: result.add(parseStepToken(item.getStr()))
      of JNull: result.add(Rest)
      else:
        raise newException(ChorusError, "bad step value: " & $item)
  of JString:
    var text = node.getStr()
    for bad in ["[", "]", "(", ")", "\n", "\t", ";", "|", ","]:
      text = text.replace(bad, " ")
    for piece in text.split(' '):
      if piece.strip().len > 0:
        tokens.add(piece)
    for token in tokens:
      result.add(parseStepToken(token))
  else:
    raise newException(ChorusError, "steps must be an array or a string")
  if result.len != Steps:
    raise newException(ChorusError,
      "steps must be exactly " & $Steps & " values, got " & $result.len)
  for value in result:
    if value != Rest and (value < 0 or value > MaxToken):
      raise newException(ChorusError,
        "every step is -1 (rest) or 0.." & $MaxToken & ", got " & $value)

proc parseDecision*(payload: JsonNode, turn: int): Decision =
  ## `target` may be an integer, a float or a numeric string; a MISSING
  ## target means "this turn's new bar" (documented in the prompt).
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen)
    .replace("\n", " ")
  result.steps = parseSteps(payload{"steps"})
  let node = payload{"target"}
  var target = turn
  if not node.isNil and node.kind != JNull:
    case node.kind
    of JInt:
      target = int(node.getInt())
    of JFloat:
      target = int(round(node.getFloat()))
    of JString:
      let text = node.getStr().strip()
      try:
        target = int(round(parseFloat(text)))
      except ValueError:
        raise newException(ChorusError, "target is not a number: " & text)
    else:
      raise newException(ChorusError, "target must be a number: " & $node)
  if target < 0 or target > turn:
    raise newException(ChorusError,
      "target must be 0.." & $turn & ": " & $target)
  result.target = target

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the `arpeggio` baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  var reasons = newSeq[string](seats.len)
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skArpeggio else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add(sim.retryHint(reasons[index]))
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var decision = parseDecision(extractJsonObject(text), sim.turn)
        ## Reject illegal replies here so the retry carries the hint.
        var probe = sim
        probe.applyBar(seat, decision.target, decision.steps, decision.say,
          decision.notes, false)
        result[index] = decision
      except CatchableError as error:
        reasons[index] = cleanText(error.msg, MaxErrorLen)
        echo "chorus llm: seat ", seat, " attempt ", attempt, " failed: ",
          reasons[index]
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "chorus llm: seat ", seat, " falling back to the arpeggio baseline"
    result[index] = scriptedAction(sim, seat, skArpeggio)
