## Sim unit tests for Chorus: the seeded setup, the notation, the hold /
## edit rules, every component of the public metric on hand-built grids, the
## counterfactual credit, rune-safe truncation, replay re-derivation, the two
## endings, the results shape, and the two name spaces.

import std/[json, math, random, sets, strutils, unicode, unittest]
import chorus/[llm, sim]

proc fixtureConfig(bars = 8, seed = 0, talk = true): GameConfig =
  result = defaultGameConfig()
  result.bars = bars
  result.seed = seed
  result.talk = talk
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc rests(): seq[int] =
  result = newSeq[int](Steps)
  for index in 0 ..< Steps:
    result[index] = Rest

proc filled(token: int): seq[int] =
  result = newSeq[int](Steps)
  for index in 0 ..< Steps:
    result[index] = token

proc onlyAt(steps: openArray[int], token: int): seq[int] =
  result = rests()
  for step in steps:
    result[step] = token

proc plainSim(bars = 4, seed = 0): Sim =
  ## A sim with the key pinned to C ionian, so hand-built grids have exactly
  ## the intervals the tables in scoring.md describe.
  result = initSim(fixtureConfig(bars = bars, seed = seed))
  result.root = 0
  result.rootName = "C"
  result.mode = 0

proc setBar(grid: var Grid, voice, bar: int, steps: seq[int]) =
  for index in 0 ..< Steps:
    grid[voice][bar][index] = steps[index]

proc writeAll(sim: var Sim, steps: seq[int]) =
  ## Every pending seat writes `steps` into this turn's new bar.
  for seat in sim.pendingSeats():
    sim.applyBar(seat, sim.turn, steps, "", "", true)

suite "seeded setup":
  test "voices, key, mode, tempo and the chord plan all come from the seed":
    for seed in [0, 1, 5, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var seen = initHashSet[int]()
      for seat in 0 ..< Seats:
        seen.incl(sim.voiceOf[seat])
        check sim.seatOf[sim.voiceOf[seat]] == seat
      check seen.len == Voices
      check sim.root in RootPitches
      check sim.mode in 0 .. 3
      check sim.bpm in [84, 90, 96, 102, 108]
      check sim.chords.len == sim.config.bars
      var matches = 0
      for progression in Progressions:
        var all = true
        for bar in 0 ..< sim.chords.len:
          if sim.chords[bar] != progression[bar mod 4]:
            all = false
        if all:
          inc matches
      check matches >= 1

  test "different seeds move the bass, the root and the mode":
    var basses = initHashSet[int]()
    var roots = initHashSet[int]()
    var modes = initHashSet[int]()
    for seed in 0 ..< 20:
      let sim = initSim(fixtureConfig(seed = seed))
      basses.incl(sim.seatOf[0])
      roots.incl(sim.root)
      modes.incl(sim.mode)
    check basses.len > 1
    check roots.len > 1
    check modes.len > 1

  test "the same seed reproduces the episode exactly":
    let a = initSim(fixtureConfig(seed = 77))
    let b = initSim(fixtureConfig(seed = 77))
    check a.voiceOf == b.voiceOf
    check a.root == b.root
    check a.mode == b.mode
    check a.bpm == b.bpm
    check a.chords == b.chords
    check a.names == b.names
    var differs = false
    for seed in 78 .. 90:
      let c = initSim(fixtureConfig(seed = seed))
      if c.voiceOf != a.voiceOf or c.root != a.root or c.mode != a.mode or
          c.bpm != a.bpm or c.chords != a.chords:
        differs = true
    check differs

suite "notation":
  test "tokens map into the voice's own two-octave register":
    let sim = plainSim()
    for voice in 0 ..< Voices:
      let base = sim.baseMidi(voice)
      check sim.midiOf(voice, Rest) == Rest
      var previous = -1
      for token in 0 .. MaxToken:
        let midi = sim.midiOf(voice, token)
        check midi >= base
        check midi <= base + 23
        check midi > previous
        previous = midi
    ## And every legal note in every key lands inside the published range.
    for seed in 0 ..< 12:
      let seeded = initSim(fixtureConfig(seed = seed))
      for voice in 0 ..< Voices:
        for token in 0 .. MaxToken:
          check seeded.midiOf(voice, token) in 36 .. 104

suite "turns":
  test "bar 0 opens silent and every turn holds the previous bar":
    var sim = initSim(fixtureConfig(bars = 6, seed = 3))
    for voice in 0 ..< Voices:
      for step in 0 ..< Steps:
        check sim.grid[voice][0][step] == Rest
    ## Turn 0: every seat writes a distinct bar.
    for seat in sim.pendingSeats():
      sim.applyBar(seat, 0, onlyAt([0, 4, 8, 12], seat), "", "", true)
    check sim.turn == 1
    check sim.turnsPlayed == 1
    for voice in 0 ..< Voices:
      check sim.grid[voice][1] == sim.grid[voice][0]
      check not sim.barIn[voice]

  test "illegal bars raise and leave the sim untouched":
    var sim = initSim(fixtureConfig(bars = 6, seed = 1))
    let before = $sim.tableStateJson()
    let events = sim.events.len
    var short = rests()
    short.setLen(Steps - 1)
    var long = rests()
    long.add(0)
    expect ChorusError:
      sim.applyBar(0, -1, rests(), "", "", false)
    expect ChorusError:
      sim.applyBar(0, sim.turn + 1, rests(), "", "", false)
    expect ChorusError:
      sim.applyBar(0, 0, short, "", "", false)
    expect ChorusError:
      sim.applyBar(0, 0, long, "", "", false)
    expect ChorusError:
      sim.applyBar(0, 0, onlyAt([0], -2), "", "", false)
    expect ChorusError:
      sim.applyBar(0, 0, onlyAt([0], MaxToken + 1), "", "", false)
    expect ChorusError:
      sim.applyBar(-1, 0, rests(), "", "", false)
    check $sim.tableStateJson() == before
    check sim.events.len == events
    ## A second bar from the same seat in one turn.
    sim.applyBar(0, 0, filled(0), "", "", false)
    expect ChorusError:
      sim.applyBar(0, 0, filled(1), "", "", false)
    check sim.pendingSeats() == @[1, 2, 3]
    check sim.turn == 0
    ## And nothing at all after the episode is over.
    var done = initSim(fixtureConfig(bars = 4, seed = 1))
    done.endEarly()
    expect ChorusError:
      done.applyBar(0, 0, rests(), "", "", false)

  test "an edit rewrites the past and the hold still stands":
    var sim = initSim(fixtureConfig(bars = 6, seed = 2))
    let motif = onlyAt([0, 4, 8, 12], 0)
    sim.writeAll(motif)
    check sim.turn == 1
    let seat = 0
    let voice = sim.voiceOf[seat]
    let repair = onlyAt([2, 6, 10], 3)
    sim.applyBar(seat, 0, repair, "", "", false)
    for step in 0 ..< Steps:
      check sim.grid[voice][0][step] == repair[step]
      ## The hold at this turn's bar is untouched by the edit.
      check sim.grid[voice][1][step] == motif[step]
    check sim.events[^1].kind == evBar
    check sim.events[^1].edit
    check sim.lastEdit[voice]
    check sim.lastTarget[voice] == 0
    for other in sim.pendingSeats():
      sim.applyBar(other, 1, motif, "", "", false)
    check sim.events[^1].kind == evTurn
    var writeEvents = 0
    for event in sim.events:
      if event.kind == evBar and event.turn == 1 and not event.edit:
        inc writeEvents
    check writeEvents == 3

suite "the metric":
  test "components take their documented values on hand-built grids":
    let sim = plainSim(bars = 4)
    ## Consonance: a bar of perfect fifths scores 1.0, minor seconds 0.0.
    var fifths = blankGrid(4)
    fifths.setBar(0, 0, filled(0))
    fifths.setBar(1, 0, filled(4))
    check sim.pieceScore(fifths, 1).consonance == 1.0
    var seconds = blankGrid(4)
    seconds.setBar(0, 0, filled(2))
    seconds.setBar(1, 0, filled(3))
    check sim.pieceScore(seconds, 1).consonance == 0.0
    ## Voice leading: one voice moving only by scale steps scores 1.0.
    var stepwise = blankGrid(4)
    var line = rests()
    for step in 0 ..< Steps:
      line[step] = step mod 2
    stepwise.setBar(0, 0, line)
    check sim.pieceScore(stepwise, 1).leading == 1.0
    ## Pulse: every onset on a strong step gives Ra == 1.0.
    var strong = blankGrid(4)
    strong.setBar(0, 0, onlyAt([0, 4, 8, 12], 0))
    strong.setBar(1, 0, onlyAt([0, 8], 2))
    check rhythmParts(strong, 1).pulse == 1.0
    ## Parallel fifths halve the voice-leading term exactly.
    var parallel = blankGrid(4)
    var lower = rests()
    var upper = rests()
    for step in 0 .. 3:
      lower[step] = step
      upper[step] = step + 4
    parallel.setBar(0, 0, lower)
    parallel.setBar(1, 0, upper)
    let cut = sim.pieceScore(parallel, 1).leading
    ## Every motion here is a scale step, so the uncut term is 1.0 and the
    ## documented factor is (1 - 0.5 * 1).
    check abs(cut - 0.5) < 1e-9

  test "novelty peaks at half a bar changed":
    let sim = plainSim(bars = 4)
    ## Every voice identical in every bar: pure repetition scores 0.
    var same = blankGrid(4)
    for voice in 0 ..< Voices:
      for bar in 0 ..< 4:
        same.setBar(voice, bar, onlyAt([0, 4, 8, 12], voice))
    check sim.pieceScore(same, 4).novelty == 0.0
    ## Every bar different in every step: never repeating scores 0 too.
    var allNew = blankGrid(4)
    for voice in 0 ..< Voices:
      for bar in 0 ..< 4:
        allNew.setBar(voice, bar, filled(bar))
    check sim.pieceScore(allNew, 4).novelty == 0.0
    ## Exactly half the bar changed: the peak.
    var half = blankGrid(4)
    for voice in 0 ..< Voices:
      half.setBar(voice, 0, filled(0))
      var second = filled(0)
      for step in 8 ..< Steps:
        second[step] = 1
      half.setBar(voice, 1, second)
    check sim.pieceScore(half, 2).novelty == 1.0

  test "the piece score is total and bounded":
    let sim = plainSim(bars = 4)
    var rng = initRand(20260824)
    for trial in 0 ..< 200:
      var grid = blankGrid(4)
      for voice in 0 ..< Voices:
        for bar in 0 ..< 4:
          var steps = rests()
          for step in 0 ..< Steps:
            steps[step] =
              if rng.rand(1.0) < 0.45: Rest else: rng.rand(MaxToken)
          grid.setBar(voice, bar, steps)
      let parts = sim.pieceScore(grid, 4)
      check parts.piece >= 0.0
      check parts.piece <= 100.0
      for value in [parts.consonance, parts.leading, parts.rhythm,
          parts.novelty]:
        check value >= 0.0
        check value <= 1.0
    let silence = blankGrid(4)
    let quiet = sim.pieceScore(silence, 4)
    check quiet.piece == 0.0
    check quiet.consonance == 0.0
    check quiet.leading == 0.0
    check quiet.rhythm == 0.0
    check quiet.novelty == 0.0

suite "the counterfactual":
  test "credit is exactly the leave-one-out difference":
    var sim = plainSim(bars = 4, seed = 9)
    var rng = initRand(4242)
    for trial in 0 ..< 50:
      var grid = blankGrid(4)
      for voice in 0 ..< Voices:
        for bar in 0 ..< 4:
          var steps = rests()
          for step in 0 ..< Steps:
            steps[step] =
              if rng.rand(1.0) < 0.5: Rest else: rng.rand(MaxToken)
          grid.setBar(voice, bar, steps)
      sim.grid = grid
      sim.turnsPlayed = 4
      let whole = sim.pieceScore(grid, 4).piece
      let running = sim.credits(4)
      for seat in 0 ..< Seats:
        let without =
          sim.pieceScore(mutedGrid(grid, sim.voiceOf[seat]), 4).piece
        check running[seat] == whole - without

  test "muting a silent voice is worth nothing at all":
    var sim = plainSim(bars = 4, seed = 11)
    var grid = blankGrid(4)
    for voice in 1 ..< Voices:
      for bar in 0 ..< 4:
        grid.setBar(voice, bar, onlyAt([0, 4, 8, 12], voice))
    sim.grid = grid
    sim.turnsPlayed = 4
    let running = sim.credits(4)
    check running[sim.seatOf[0]] == 0.0

  test "a voice the piece is better off without scores below zero":
    var sim = plainSim(bars = 4, seed = 13)
    var grid = blankGrid(4)
    ## Voices 1, 2 and 3 are mutually consonant on every step; voice 0 grinds
    ## a minor second against the tenor and fills every column so all four
    ## sound at once.
    grid.setBar(0, 0, filled(6))
    grid.setBar(1, 0, filled(0))
    grid.setBar(2, 0, filled(2))
    grid.setBar(3, 0, filled(4))
    for bar in 1 ..< 4:
      for voice in 0 ..< Voices:
        grid[voice][bar] = grid[voice][0]
    sim.grid = grid
    sim.turnsPlayed = 4
    let running = sim.credits(4)
    check running[sim.seatOf[0]] < 0.0

  test "the density denominator stays four voices in the muted call":
    var grid = blankGrid(4)
    for voice in 0 ..< Voices:
      for bar in 0 ..< 4:
        grid.setBar(voice, bar, onlyAt([0, 4, 8, 12], voice))
    ## 16 onsets in 64 slots is 0.25: inside the band, so Rb is exactly 1.
    check rhythmParts(grid, 4).density == 1.0
    ## Muting one voice leaves 12 onsets. Over four voices that is 0.1875,
    ## below the band and so strictly under 1. Over THREE voices it would be
    ## 0.25 again — which is what a wrong denominator would report.
    check rhythmParts(mutedGrid(grid, 0), 4).density < 1.0

suite "recorded strings":
  test "say and notes are cut on rune boundaries and stay valid UTF-8":
    var sim = initSim(fixtureConfig(bars = 6, seed = 1))
    var longSay = ""
    for index in 0 ..< 400:
      longSay.add("音")
    var longNotes = ""
    for index in 0 ..< 900:
      longNotes.add("音")
    sim.applyBar(0, 0, filled(0), longSay, longNotes, false)
    let voice = sim.voiceOf[0]
    check sim.says[voice].runeLen <= MaxSayLen
    check sim.says[voice].runeLen == MaxSayLen
    check sim.says[voice].validateUtf8() == -1
    check sim.notes[0].runeLen <= MaxNotesLen
    check sim.notes[0].runeLen == MaxNotesLen
    check sim.notes[0].validateUtf8() == -1
    for event in sim.events:
      check event.say.validateUtf8() == -1
      check event.text.validateUtf8() == -1
      let bytes = $event.eventToJson()
      check bytes.validateUtf8() == -1
      let back = eventFromJson(parseJson(bytes))
      check back.say == event.say
      check back.text == event.text
    ## Talk off silences the line entirely.
    var quiet = initSim(fixtureConfig(bars = 6, seed = 1, talk = false))
    quiet.applyBar(0, 0, filled(0), "hello", "", false)
    check quiet.says[quiet.voiceOf[0]] == ""

suite "replay":
  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(bars = 6, seed = 11)
    var live = initSim(config)
    var turn = 0
    while not live.done:
      for seat in live.pendingSeats():
        let target = if turn == 3 and seat == 1: 1 else: live.turn
        live.applyBar(seat, target,
          onlyAt([0, 4, 8, 12], (seat + turn) mod (MaxToken + 1)),
          "line " & $turn, "note " & $seat & "/" & $turn, false)
      inc turn
    check live.reason == "complete"
    check live.events.len == 5 * config.bars + 3
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].done
    check frames[^1].reason == "complete"

  test "events round-trip and a tampered turn event is rejected":
    let config = fixtureConfig(bars = 4, seed = 12)
    var live = initSim(config)
    live.writeAll(onlyAt([0, 4, 8, 12], 2))
    var kinds = initHashSet[EventKind]()
    for event in live.events:
      kinds.incl(event.kind)
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.turn == event.turn
      check back.seat == event.seat
      check back.voice == event.voice
      check back.target == event.target
      check back.edit == event.edit
      check back.steps == event.steps
      check back.say == event.say
      check back.scripted == event.scripted
      check back.text == event.text
      check back.chord == event.chord
      check abs(back.piece - round6(event.piece)) < 1e-9
      check back.credits.len == event.credits.len
    check evStart in kinds
    check evTurn in kinds
    check evBar in kinds
    var moved = live.events
    for index in 0 ..< moved.len:
      if moved[index].kind == evTurn and moved[index].turn == 1:
        moved[index].piece += 1.0
    expect ChorusError:
      discard replayMatch(config, moved)
    var rechorded = live.events
    for index in 0 ..< rechorded.len:
      if rechorded[index].kind == evTurn and rechorded[index].turn == 1:
        rechorded[index].chord = (rechorded[index].chord + 1) mod 7
    expect ChorusError:
      discard replayMatch(config, rechorded)

  test "a recorded deadline settles the replayed sim":
    let config = fixtureConfig(bars = 8, seed = 14)
    var short = initSim(config)
    short.writeAll(onlyAt([0, 8], 0))
    short.writeAll(onlyAt([2, 10], 1))
    short.endEarly()
    check short.events[^1].kind == evEnd
    let frames = replayMatch(config, short.events)
    check frames.len == short.events.len + 1
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check frames[^1].turnsPlayed == 2
    check $frames[^1].tableStateJson() == $short.tableStateJson()

suite "endings and results":
  test "complete and deadline are the only two endings":
    let config = fixtureConfig(bars = 5, seed = 15)
    var full = initSim(config)
    for turn in 0 ..< 5:
      check not full.done
      full.writeAll(onlyAt([0, 4, 8, 12], turn))
    check full.done
    check full.reason == "complete"
    check full.turnsPlayed == 5
    check full.reason in ["complete", "deadline"]
    var early = initSim(config)
    early.writeAll(onlyAt([0, 4, 8, 12], 1))
    early.writeAll(onlyAt([2, 6, 10, 14], 3))
    let credited = early.credits(early.turnsPlayed)
    early.endEarly()
    check early.done
    check early.reason == "deadline"
    check early.turnsPlayed == 2
    check early.pendingSeats().len == 0
    let events = early.events.len
    early.endEarly()
    check early.events.len == events
    check early.resultsJson()["reason"].getStr() == "deadline"
    for seat in 0 ..< Seats:
      check abs(early.resultsJson()["scores"][seat].getFloat() -
        round6(credited[seat])) < 1e-9

  test "the results shape is what the platform is promised":
    let config = fixtureConfig(bars = 6, seed = 16)
    var sim = initSim(config)
    var turn = 0
    while not sim.done:
      for seat in sim.pendingSeats():
        sim.applyBar(seat, sim.turn,
          onlyAt([0, 4, 8, 12], (seat * 2 + turn) mod 8), "", "", true)
      inc turn
    let results = sim.resultsJson()
    for key in ["names", "scores", "voices", "onsets"]:
      check results[key].len == Seats
    check results["piece"].getFloat() >= 0.0
    check results["piece"].getFloat() <= 100.0
    for key in ["consonance", "leading", "rhythm", "novelty"]:
      check results[key].getFloat() >= 0.0
      check results[key].getFloat() <= 1.0
    check results["bars"].getInt() <= results["maxBars"].getInt()
    check results["maxBars"].getInt() == 6
    check results["reason"].getStr() == "complete"
    for seat in 0 ..< Seats:
      check results["voices"][seat].getStr() == sim.voiceName(seat)
      var onsets = 0
      for bar in 0 ..< sim.turnsPlayed:
        for step in 0 ..< Steps:
          if sim.grid[sim.voiceOf[seat]][bar][step] >= 0:
            inc onsets
      check results["onsets"][seat].getInt() == onsets
      check results["names"][seat].getStr() ==
        config.players[seat].name

suite "name spaces":
  test "prompts carry cog aliases and never a policy name":
    var config = fixtureConfig(bars = 6, seed = 17)
    config.players = @[]
    let policyNames = @["chorus-cantor", "chorus-weaver", "chorus-arpeggio",
      "chorus-pedal"]
    for name in policyNames:
      config.players.add(PlayerConfig(name: name))
    var sim = initSim(config)
    sim.writeAll(onlyAt([0, 4, 8, 12], 0))
    for seat in 0 ..< Seats:
      let system = systemPrompt(sim, seat)
      let user = sim.userPrompt(seat, "operator guidance here")
      check sim.names[seat] in system
      check sim.names[seat] in user
      check "operator guidance here" in user
      check "LEGAL TARGETS THIS TURN" in user
      check "COUNTERFACTUAL" in system
      for name in policyNames:
        check name notin system
        check name notin user
    ## And the aliases themselves are a deterministic function of the seed.
    check tableNames(config.players, 17) == tableNames(config.players, 17)
    var aliasSets = initHashSet[string]()
    for seed in 0 ..< 12:
      aliasSets.incl(tableNames(config.players, seed).join(","))
    check aliasSets.len > 1
