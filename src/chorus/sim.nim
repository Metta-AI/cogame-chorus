## Pure game rules for Chorus. No IO, no networking, no LLM — the server,
## the tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded seat→voice assignment, the key,
## mode, tempo and chord plan, the 4 × bars × 16 note grid, each seat's
## private notes, and the append-only event log. Everything random is drawn
## from the seed at `initSim`, so a replay re-derives the episode from the
## recorded `bar` events alone.

import std/[json, math, random, strutils, unicode], types

export types

const
  Voices* = 4
  Seats* = 4
  Steps* = 16
  Rest* = -1
  MaxToken* = 13
  MinBars* = 4
  MaxBars* = 16
  MaxSayLen* = 100
  ## The private notebook a seat may carry between turns.
  MaxNotesLen* = 600
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  VoiceNames* = ["Bass", "Tenor", "Alto", "Soprano"]
  BaseMidi* = [36, 48, 60, 72]
  RootPitches* = [0, 2, 3, 5, 7, 9]
  RootNames* = ["C", "D", "E♭", "F", "G", "A"]
  ModeNames* = ["ionian", "dorian", "aeolian", "mixolydian"]
  Scales* = [
    [0, 2, 4, 5, 7, 9, 11],   # ionian
    [0, 2, 3, 5, 7, 9, 10],   # dorian
    [0, 2, 3, 5, 7, 8, 10],   # aeolian
    [0, 2, 4, 5, 7, 9, 10]    # mixolydian
  ]
  Progressions* = [
    [0, 3, 4, 0],   # I  IV V  I
    [0, 5, 3, 4],   # I  vi IV V
    [0, 4, 5, 3],   # I  V  vi IV
    [5, 3, 0, 4]    # vi IV I  V
  ]
  ## Roman numerals for a chord rooted on each scale degree.
  ChordNames* = ["I", "ii", "iii", "IV", "V", "vi", "vii"]
  ## Interval-class quality, indexed by |Δmidi| mod 12.
  ConsonanceW*: array[12, float] = [
    0.6, 0.0, 0.3, 1.0, 1.0, 0.7, 0.1, 1.0, 0.9, 0.9, 0.3, 0.0
  ]
  ## Metric weight per onset by its step index inside the bar.
  PulseW*: array[Steps, float] = [
    1.0, 0.4, 0.7, 0.4, 1.0, 0.4, 0.7, 0.4,
    1.0, 0.4, 0.7, 0.4, 1.0, 0.4, 0.7, 0.4
  ]
  WeightConsonance* = 0.35
  WeightLeading* = 0.25
  WeightRhythm* = 0.25
  WeightNovelty* = 0.15
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  Phase* = enum
    phBars = "bars"     ## the live turn is waiting for its four bars
    phDone = "done"

  Bar* = array[Steps, int]

  Grid* = array[Voices, seq[Bar]]

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## anonymous aliases per seat
    voiceOf*: array[Seats, int]      ## seat -> voice
    seatOf*: array[Voices, int]      ## voice -> seat
    root*: int                       ## root pitch class
    rootName*: string
    mode*: int
    bpm*: int
    chords*: seq[int]                ## one chord-root degree per bar
    grid*: Grid                      ## [voice][bar][step]
    turn*: int                       ## the live turn
    barIn*: array[Voices, bool]      ## this turn's bar submitted?
    lastTarget*: array[Voices, int]
    lastEdit*: array[Voices, bool]
    says*: array[Voices, string]
    heard*: array[Voices, string]
    notes*: seq[string]              ## latest private notes per seat
    turnsPlayed*: int
    phase*: Phase
    done*: bool
    reason*: string                  ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Small helpers ----------------------------------------------------------

proc round6*(value: float): float =
  ## Every float that reaches the replay is rounded to six decimals, so the
  ## recorded bytes and a re-derivation compare equal.
  round(value * 1_000_000.0) / 1_000_000.0

proc clamp01(value: float): float =
  if value < 0.0: 0.0 elif value > 1.0: 1.0 else: value

proc restBar*(): Bar =
  for step in 0 ..< Steps:
    result[step] = Rest

proc blankGrid*(bars: int): Grid =
  for voice in 0 ..< Voices:
    result[voice] = newSeq[Bar](bars)
    for bar in 0 ..< bars:
      result[voice][bar] = restBar()

proc chordName*(degree: int): string =
  if degree < 0 or degree >= ChordNames.len: "?" else: ChordNames[degree]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the bar count into the episode's limits. Idempotent: a config that
  ## already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.bars = max(min(config.bars, MaxBars), MinBars)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.bars, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, turn: -1, seat: -1, voice: -1, target: -1, chord: -1)

# ---- Queries ----------------------------------------------------------------

proc voiceName*(sim: Sim, seat: int): string =
  VoiceNames[sim.voiceOf[seat]]

proc baseMidi*(sim: Sim, voice: int): int =
  ## The lowest MIDI note this voice can write in the episode's key.
  BaseMidi[voice] + sim.root

proc midiOf*(sim: Sim, voice, token: int): int =
  ## Scale degree -> MIDI note. A rest stays a rest.
  if token < 0:
    return Rest
  sim.baseMidi(voice) + 12 * (token div 7) + Scales[sim.mode][token mod 7]

proc pendingSeats*(sim: Sim): seq[int] =
  ## Seats whose bar for the live turn is still due, in seat order. Empty
  ## once the episode is over.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if not sim.barIn[sim.voiceOf[seat]]:
      result.add(seat)

proc legalTargets*(sim: Sim): seq[int] =
  ## The bar indexes a seat may write this turn — the SAME predicate
  ## `applyBar` validates with, so a prompt never has to guess the set.
  if sim.done:
    return
  for target in 0 .. sim.turn:
    result.add(target)

proc keyName*(sim: Sim): string =
  sim.rootName & " " & ModeNames[sim.mode]

# ---- The metric -------------------------------------------------------------

proc motionScore(leap: int): float =
  if leap <= 2: 1.00
  elif leap <= 4: 0.85
  elif leap <= 7: 0.60
  elif leap <= 12: 0.30
  else: 0.00

proc densityScore(density: float): float =
  if density < 0.05 or density > 0.85: 0.0
  elif density < 0.20: (density - 0.05) / 0.15
  elif density <= 0.55: 1.0
  else: (0.85 - density) / 0.30

proc consonanceScore*(sim: Sim, grid: Grid, n: int): float =
  ## Mean interval quality over every simultaneously sounding voice pair.
  ## Silence is NOT consonance: with no sounding pair at all the term is 0.
  var total = 0.0
  var count = 0
  for bar in 0 ..< n:
    for step in 0 ..< Steps:
      for lower in 0 ..< Voices:
        if grid[lower][bar][step] < 0:
          continue
        let lowerMidi = sim.midiOf(lower, grid[lower][bar][step])
        for upper in lower + 1 ..< Voices:
          if grid[upper][bar][step] < 0:
            continue
          let ic = abs(lowerMidi - sim.midiOf(upper, grid[upper][bar][step])) mod 12
          total += ConsonanceW[ic]
          inc count
  if count == 0: 0.0 else: total / count.float

proc leadingScore*(sim: Sim, grid: Grid, n: int): float =
  ## Mean motion quality across every voice, cut by the share of eligible
  ## voice pairs that move in parallel fifths or octaves.
  var total = 0.0
  var count = 0
  for voice in 0 ..< Voices:
    var previous = -1
    for bar in 0 ..< n:
      for step in 0 ..< Steps:
        let token = grid[voice][bar][step]
        if token < 0:
          continue
        let midi = sim.midiOf(voice, token)
        if previous >= 0:
          total += motionScore(abs(midi - previous))
          inc count
        previous = midi
  let raw = if count == 0: 0.0 else: total / count.float
  var eligible = 0
  var parallel = 0
  let columns = n * Steps
  for lower in 0 ..< Voices:
    for upper in lower + 1 ..< Voices:
      for index in 0 ..< max(columns - 1, 0):
        let barA = index div Steps
        let stepA = index mod Steps
        let barB = (index + 1) div Steps
        let stepB = (index + 1) mod Steps
        let lowA = grid[lower][barA][stepA]
        let lowB = grid[lower][barB][stepB]
        let upA = grid[upper][barA][stepA]
        let upB = grid[upper][barB][stepB]
        if lowA < 0 or lowB < 0 or upA < 0 or upB < 0:
          continue
        let lowMidiA = sim.midiOf(lower, lowA)
        let lowMidiB = sim.midiOf(lower, lowB)
        let upMidiA = sim.midiOf(upper, upA)
        let upMidiB = sim.midiOf(upper, upB)
        if lowMidiA == lowMidiB or upMidiA == upMidiB:
          continue
        inc eligible
        let icA = abs(lowMidiA - upMidiA) mod 12
        let icB = abs(lowMidiB - upMidiB) mod 12
        if icA == icB and (icA == 0 or icA == 7):
          inc parallel
  let share = if eligible == 0: 0.0 else: parallel.float / eligible.float
  raw * (1.0 - 0.5 * share)

proc rhythmParts*(grid: Grid, n: int):
    tuple[pulse, density, interlock: float] =
  ## The three rhythm terms, exposed so tests can pin each one. The density
  ## denominator is ALWAYS four voices — including in the counterfactual,
  ## where a muted voice still costs the piece its share of the grid.
  var pulseTotal = 0.0
  var onsets = 0
  var interlocked = 0
  for bar in 0 ..< n:
    for step in 0 ..< Steps:
      var sounding = 0
      for voice in 0 ..< Voices:
        if grid[voice][bar][step] >= 0:
          inc sounding
          pulseTotal += PulseW[step]
      onsets += sounding
      if sounding >= 1 and sounding <= 3:
        inc interlocked
  let columns = n * Steps
  result.pulse = if onsets == 0: 0.0 else: pulseTotal / onsets.float
  result.density =
    if columns == 0: 0.0
    else: densityScore(onsets.float / (columns * Voices).float)
  result.interlock =
    if columns == 0: 0.0 else: interlocked.float / columns.float

proc rhythmScore*(grid: Grid, n: int): float =
  let parts = rhythmParts(grid, n)
  0.40 * parts.pulse + 0.35 * parts.density + 0.25 * parts.interlock

proc noveltyRaw*(grid: Grid, n: int): float =
  ## Mean distance from each bar to the closest earlier bar of the SAME
  ## voice. Rests match rests.
  if n < 2:
    return 0.5
  var total = 0.0
  var count = 0
  for voice in 0 ..< Voices:
    for bar in 1 ..< n:
      var best = 0
      for earlier in 0 ..< bar:
        var same = 0
        for step in 0 ..< Steps:
          if grid[voice][bar][step] == grid[voice][earlier][step]:
            inc same
        if same > best:
          best = same
      total += 1.0 - best.float / Steps.float
      inc count
  if count == 0: 0.5 else: total / count.float

proc noveltyScore*(grid: Grid, n: int): float =
  ## The target is that about HALF of a bar differs from its closest earlier
  ## sibling: pure repetition scores 0 and so does never repeating anything.
  let raw = noveltyRaw(grid, n)
  max(0.0, 1.0 - 2.0 * abs(raw - 0.5))

proc pieceScore*(sim: Sim, grid: Grid, n: int):
    tuple[piece, consonance, leading, rhythm, novelty: float] =
  ## The one and only scoring path: the live scoreboard, the results, the
  ## replay check and the counterfactual all call this.
  result.consonance = clamp01(sim.consonanceScore(grid, n))
  result.leading = clamp01(sim.leadingScore(grid, n))
  result.rhythm = clamp01(rhythmScore(grid, n))
  result.novelty = clamp01(noveltyScore(grid, n))
  result.piece = 100.0 * (
    WeightConsonance * result.consonance +
    WeightLeading * result.leading +
    WeightRhythm * result.rhythm +
    WeightNovelty * result.novelty
  )

proc mutedGrid*(grid: Grid, voice: int): Grid =
  ## Every token of `voice` becomes a rest; the bars themselves remain, so
  ## they still count in the novelty mean, the interlock columns and the
  ## density denominator.
  result = grid
  result[voice] = @[]
  for bar in grid[voice]:
    result[voice].add(restBar())

proc credits*(sim: Sim, n: int): array[Seats, float] =
  ## credit(seat) = piece(as written) − piece(with that seat's voice deleted).
  ## Signed: a voice the piece would be better off without scores below zero.
  let whole = sim.pieceScore(sim.grid, n).piece
  for seat in 0 ..< Seats:
    let without = sim.pieceScore(mutedGrid(sim.grid, sim.voiceOf[seat]), n).piece
    result[seat] = whole - without

proc score*(sim: Sim, seat: int): float =
  sim.credits(sim.turnsPlayed)[seat]

proc onsetsOf*(sim: Sim, voice, n: int): int =
  for bar in 0 ..< min(n, sim.grid[voice].len):
    for step in 0 ..< Steps:
      if sim.grid[voice][bar][step] >= 0:
        inc result

# ---- Turn bookkeeping -------------------------------------------------------

proc turnEvent*(sim: Sim): GameEvent =
  ## The `turn` event for the current state: the running score over the bars
  ## that have resolved. Emitted when a turn opens and once more when the
  ## piece is finished; a replay re-derives it and compares.
  result = blankEvent(evTurn)
  result.turn = sim.turn
  result.chord =
    if sim.turn >= 0 and sim.turn < sim.chords.len: sim.chords[sim.turn]
    else: -1
  let parts = sim.pieceScore(sim.grid, sim.turnsPlayed)
  result.piece = round6(parts.piece)
  result.parts = [round6(parts.consonance), round6(parts.leading),
    round6(parts.rhythm), round6(parts.novelty)]
  let running = sim.credits(sim.turnsPlayed)
  for seat in 0 ..< Seats:
    result.credits.add(round6(running[seat]))

proc openTurn(sim: var Sim) =
  ## The live turn opens: every voice HOLDS its previous bar, last turn's
  ## messages move into `heard`, and the running score is logged.
  for voice in 0 ..< Voices:
    if sim.turn > 0:
      sim.grid[voice][sim.turn] = sim.grid[voice][sim.turn - 1]
    else:
      sim.grid[voice][sim.turn] = restBar()
    sim.barIn[voice] = false
    sim.lastTarget[voice] = -1
    sim.lastEdit[voice] = false
  sim.heard = sim.says
  sim.says = ["", "", "", ""]
  sim.phase = phBars
  sim.addEvent(sim.turnEvent())

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(ChorusError,
      "chorus needs exactly " & $Seats & " players")
  if config.bars < MinBars or config.bars > MaxBars:
    raise newException(ChorusError,
      "bars must be " & $MinBars & ".." & $MaxBars)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides, in this order: voices,
  ## root, mode, bpm, progression.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var voices = @[0, 1, 2, 3]
  rng.shuffle(voices)
  for seat in 0 ..< Seats:
    result.voiceOf[seat] = voices[seat]
    result.seatOf[voices[seat]] = seat
  let rootIndex = rng.rand(RootPitches.len - 1)
  result.root = RootPitches[rootIndex]
  result.rootName = RootNames[rootIndex]
  result.mode = rng.rand(ModeNames.len - 1)
  result.bpm = 84 + 6 * rng.rand(4)
  let progression = rng.rand(Progressions.len - 1)
  for bar in 0 ..< config.bars:
    result.chords.add(Progressions[progression][bar mod 4])
  result.grid = blankGrid(config.bars)
  result.notes = newSeq[string](Seats)
  result.turn = 0
  result.addEvent(blankEvent(evStart))
  result.openTurn()

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.turn = sim.turnsPlayed
  event.text = reason
  sim.addEvent(event)

proc resolveTurn(sim: var Sim) =
  sim.turnsPlayed = sim.turn + 1
  if sim.turnsPlayed >= sim.config.bars:
    ## The piece is finished: log the complete score, then settle.
    sim.turn = sim.config.bars
    sim.addEvent(sim.turnEvent())
    sim.settle("complete")
  else:
    sim.turn = sim.turn + 1
    sim.openTurn()

proc applyBar*(sim: var Sim, seat, target: int, steps: seq[int],
    say, notes: string, scripted: bool) =
  ## `seat` writes one bar in its own voice. Raises ChorusError on anything
  ## illegal WITHOUT mutating; the game server falls back to the scripted
  ## baseline on a rejection. The fourth bar resolves the turn.
  if sim.done:
    raise newException(ChorusError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(ChorusError, "bad seat: " & $seat)
  let voice = sim.voiceOf[seat]
  if sim.barIn[voice]:
    raise newException(ChorusError,
      sim.names[seat] & " has already written this turn")
  if target < 0 or target > sim.turn:
    raise newException(ChorusError,
      "target must be 0.." & $sim.turn & ", got " & $target)
  if steps.len != Steps:
    raise newException(ChorusError,
      "steps must be exactly " & $Steps & " values, got " & $steps.len)
  for step in steps:
    if step != Rest and (step < 0 or step > MaxToken):
      raise newException(ChorusError,
        "every step is -1 (rest) or 0.." & $MaxToken & ", got " & $step)
  var bar: Bar
  for index in 0 ..< Steps:
    bar[index] = steps[index]
  sim.grid[voice][target] = bar
  sim.barIn[voice] = true
  sim.lastTarget[voice] = target
  sim.lastEdit[voice] = target < sim.turn
  var message = say.strip()
  if not sim.config.talk:
    message = ""
  ## Cut on a rune boundary: a byte slice through a multi-byte character
  ## would leave invalid UTF-8 in the replay and break its JSON.
  if message.runeLen > MaxSayLen:
    message = message.runeSubStr(0, MaxSayLen)
  sim.says[voice] = message
  if notes.len > 0:
    ## Notes ride into the replay too, so they are cut on a rune boundary as
    ## well.
    sim.notes[seat] =
      if notes.runeLen > MaxNotesLen: notes.runeSubStr(0, MaxNotesLen)
      else: notes
  var event = blankEvent(evBar)
  event.turn = sim.turn
  event.seat = seat
  event.voice = voice
  event.target = target
  event.edit = target < sim.turn
  event.steps = steps
  event.say = message
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.resolveTurn()

proc endEarly*(sim: var Sim) =
  ## Stop now, between turns. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest piece always
  ## beats a long one that never lands. The open turn's `turn` event already
  ## carries the score over the bars actually written.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  let parts = sim.pieceScore(sim.grid, sim.turnsPlayed)
  let running = sim.credits(sim.turnsPlayed)
  var names = newJArray()
  var scores = newJArray()
  var voices = newJArray()
  var onsets = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%round6(running[seat]))
    voices.add(%sim.voiceName(seat))
    onsets.add(%sim.onsetsOf(sim.voiceOf[seat], sim.turnsPlayed))
  %*{
    "names": names,
    "scores": scores,
    "voices": voices,
    "onsets": onsets,
    "piece": round6(parts.piece),
    "consonance": round6(parts.consonance),
    "leading": round6(parts.leading),
    "rhythm": round6(parts.rhythm),
    "novelty": round6(parts.novelty),
    "key": sim.keyName(),
    "bpm": sim.bpm,
    "bars": sim.turnsPlayed,
    "maxBars": sim.config.bars,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc barJson(bar: Bar): JsonNode =
  result = newJArray()
  for step in 0 ..< Steps:
    result.add(%bar[step])

proc tableStateJson*(sim: Sim): JsonNode =
  let pending = sim.pendingSeats()
  let parts = sim.pieceScore(sim.grid, sim.turnsPlayed)
  let running = sim.credits(sim.turnsPlayed)
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let voice = sim.voiceOf[seat]
    var bars = newJArray()
    for bar in sim.grid[voice]:
      bars.add(barJson(bar))
    var heard = newJArray()
    for other in 0 ..< Voices:
      if other != voice and sim.heard[other].len > 0:
        heard.add(%*{"seat": sim.seatOf[other], "say": sim.heard[other]})
    seats.add(%*{
      "name": sim.names[seat],
      "seat": seat,
      "voice": voice,
      "voiceName": VoiceNames[voice],
      "base": sim.baseMidi(voice),
      "score": round6(running[seat]),
      "onsets": sim.onsetsOf(voice, sim.turnsPlayed),
      "bars": bars,
      "say": sim.says[voice],
      "heard": heard,
      "notes": sim.notes[seat],
      "pending": seat in pending,
      "lastTarget": sim.lastTarget[voice],
      "lastEdit": sim.lastEdit[voice]
    })
  var voiceSeat = newJArray()
  for voice in 0 ..< Voices:
    voiceSeat.add(%sim.seatOf[voice])
  var grid = newJArray()
  for voice in 0 ..< Voices:
    var lane = newJArray()
    for bar in sim.grid[voice]:
      lane.add(barJson(bar))
    grid.add(lane)
  var chords = newJArray()
  var chordNames = newJArray()
  for degree in sim.chords:
    chords.add(%degree)
    chordNames.add(%chordName(degree))
  var creditsNode = newJArray()
  for seat in 0 ..< Seats:
    creditsNode.add(%round6(running[seat]))
  var history = newJArray()
  for event in sim.events:
    if event.kind != evTurn:
      continue
    var row = newJArray()
    for value in event.credits:
      row.add(%value)
    history.add(%*{"turn": event.turn, "piece": event.piece, "credits": row})
  %*{
    "seats": seats,
    "voiceSeat": voiceSeat,
    "grid": grid,
    "chords": chords,
    "chordNames": chordNames,
    "key": sim.rootName,
    "mode": ModeNames[sim.mode],
    "bpm": sim.bpm,
    "steps": Steps,
    "turn": sim.turn,
    "turns": sim.config.bars,
    "turnsPlayed": sim.turnsPlayed,
    "piece": round6(parts.piece),
    "parts": {
      "consonance": round6(parts.consonance),
      "leading": round6(parts.leading),
      "rhythm": round6(parts.rhythm),
      "novelty": round6(parts.novelty)
    },
    "credits": creditsNode,
    "history": history,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying the
  ## BAR events through the rules — voices, key, mode, bpm and the chord plan
  ## all come from the seed. A `turn` event is a CHECK, not a source.
  ## frames[i] = state after events[0 ..< i].
  var sim = initSim(config)
  ## initSim already logged the start and the first turn event; the recorded
  ## log opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evTurn:
      let expected = sim.turnEvent()
      if event.turn != expected.turn or event.chord != expected.chord or
          abs(event.piece - expected.piece) > 1e-4:
        raise newException(ChorusError,
          "turn " & $event.turn & " does not match the seeded re-derivation")
      for index in 0 ..< 4:
        if abs(event.parts[index] - expected.parts[index]) > 1e-4:
          raise newException(ChorusError,
            "turn " & $event.turn & " components do not match")
      if event.credits.len != expected.credits.len:
        raise newException(ChorusError,
          "turn " & $event.turn & " credit count does not match")
      for index in 0 ..< event.credits.len:
        if abs(event.credits[index] - expected.credits[index]) > 1e-4:
          raise newException(ChorusError,
            "turn " & $event.turn & " credits do not match")
      ## The live log wrote this turn event when the turn opened (or, for
      ## the last one, when the piece finished); the replayed sim did too,
      ## inside the last applyBar / initSim, so nothing is appended here.
      if not sim.done and
          (sim.events.len == 0 or sim.events[^1].kind != evTurn):
        sim.events.add(event)
    of evBar:
      sim.applyBar(event.seat, event.target, event.steps, event.say,
        event.text, event.scripted)
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the bars alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.turn >= 0:
    result["turn"] = %event.turn
  case event.kind
  of evStart:
    discard
  of evTurn:
    result["chord"] = %event.chord
    result["piece"] = %round6(event.piece)
    var parts = newJArray()
    for value in event.parts:
      parts.add(%round6(value))
    result["parts"] = parts
    var credits = newJArray()
    for value in event.credits:
      credits.add(%round6(value))
    result["credits"] = credits
  of evBar:
    result["seat"] = %event.seat
    result["voice"] = %event.voice
    result["target"] = %event.target
    result["edit"] = %event.edit
    var steps = newJArray()
    for value in event.steps:
      steps.add(%value)
    result["steps"] = steps
    if event.say.len > 0:
      result["say"] = %event.say
    result["scripted"] = %event.scripted
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    turn: node{"turn"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    voice: node{"voice"}.getInt(-1),
    target: node{"target"}.getInt(-1),
    edit: node{"edit"}.getBool(false),
    say: node{"say"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    chord: node{"chord"}.getInt(-1),
    piece: node{"piece"}.getFloat(0.0)
  )
  if node.hasKey("steps"):
    for step in node["steps"]:
      result.steps.add(step.getInt())
  if node.hasKey("parts"):
    var index = 0
    for value in node["parts"]:
      if index < 4:
        result.parts[index] = value.getFloat()
      inc index
  if node.hasKey("credits"):
    for value in node["credits"]:
      result.credits.add(value.getFloat())
