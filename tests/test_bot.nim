## The scripted baselines must play whole episodes without ever proposing an
## illegal bar — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path. The
## arpeggio baseline must also actually make music, or it is no partner worth
## beating; the pedal baseline must be the weaker of the two.

import std/[json, monotimes, os, strutils, times, unicode, unittest]
import chorus/[llm, policy_view, sim]

proc fixture(seed: int, bars = 8): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.bars = bars
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kind: ScriptKind,
    strict = false): Sim =
  result = initSim(config)
  while not result.done:
    let turn = result.turn
    for seat in result.pendingSeats():
      let decision = scriptedAction(result, seat, kind)
      if strict:
        ## Every scripted bar must be legal AS IS: applyBar raises on
        ## anything else and would fail this test anyway, but assert the
        ## bounds explicitly so a regression names itself.
        check decision.target == turn
        check decision.steps.len == Steps
        var bounded = true
        for step in decision.steps:
          if step != Rest and (step < 0 or step > MaxToken):
            bounded = false
        check bounded
        check decision.say.len == 0
        check decision.notes.len == 0
      result.applyBar(seat, decision.target, decision.steps, decision.say,
        decision.notes, true)

suite "scripted baselines":
  test "seat observation reproduces policy prompt without other private notes":
    var sim = initSim(fixture(11, bars = 6))
    sim.notes[0] = "private motif"
    sim.notes[1] = "other private note"
    for seat in sim.pendingSeats():
      let decision = scriptedAction(sim, seat, skArpeggio)
      sim.applyBar(seat, decision.target, decision.steps, "hello", "", true)
    let view = sim.seatViewJson(0, true)
    check "other private note" notin $view
    check view["seat"]["notes"].getStr() == "private motif"
    let reconstructed = simFromSeatView(view)
    check reconstructed.userPrompt(0, "strategy") ==
      sim.userPrompt(0, "strategy")

  test "both baselines play full episodes legally and fast, in every voice":
    for seed in [1, 5, 42, 1234]:
      for kind in [skArpeggio, skPedal]:
        let config = fixture(seed)
        let started = getMonoTime()
        let sim = playScripted(config, kind, strict = true)
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.turnsPlayed == config.bars
        var bars = 0
        for event in sim.events:
          if event.kind == evBar:
            inc bars
            check not event.edit
            check event.steps.len == Steps
            check event.say.len == 0
        check bars == config.bars * Seats
        check sim.events.len == 5 * config.bars + 3
        ## Every voice is covered: seat->voice is a seeded permutation, so
        ## four seats of one baseline is one baseline in all four voices.
        var voices = 0
        for voice in 0 ..< Voices:
          if sim.onsetsOf(voice, sim.turnsPlayed) > 0:
            inc voices
        check voices == Voices
        check elapsed < 2000

  test "arpeggio sits in its quality band and pedal is the weaker filler":
    var total = 0.0
    var lowest = 200.0
    var highest = -1.0
    var pedalLower = 0
    let trials = 200
    for seed in 0 ..< trials:
      let arpeggio = playScripted(fixture(seed), skArpeggio)
      let pedal = playScripted(fixture(seed), skPedal)
      let a = arpeggio.pieceScore(arpeggio.grid, arpeggio.turnsPlayed).piece
      let p = pedal.pieceScore(pedal.grid, pedal.turnsPlayed).piece
      total += a
      lowest = min(lowest, a)
      highest = max(highest, a)
      if p < a:
        inc pedalLower
    echo "arpeggio piece score over ", trials, " seeds: mean ",
      formatFloat(total / trials.float, ffDecimal, 2), ", min ",
      formatFloat(lowest, ffDecimal, 2), ", max ",
      formatFloat(highest, ffDecimal, 2),
      "; pedal scored lower on ", pedalLower, "/", trials
    check lowest >= 40.0
    check highest <= 92.0
    check pedalLower.float / trials.float >= 0.9

  test "decideAll falls back to scripted with no credentials":
    let config = fixture(3, bars = 6)
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    let client = newLlmClient()
    check client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    let decisions = client.decideAll(sim, seats,
      @["write a countermelody", "", "", ""],
      @[skNone, skNone, skPedal, skNone])
    check decisions.len == Seats
    for index, seat in seats:
      let kind = if seat == 2: skPedal else: skArpeggio
      check decisions[index].steps == scriptedAction(sim, seat, kind).steps
      check decisions[index].target == sim.turn
      check decisions[index].scripted
      ## Legal as-is: applyBar raises on anything else.
      sim.applyBar(seat, decisions[index].target, decisions[index].steps,
        "", "", decisions[index].scripted)
    check sim.turn == 1
    check sim.turnsPlayed == 1

  test "a seat that fails both attempts is recorded as scripted":
    ## The retry-exhausted fallback must be distinguishable from a parsed
    ## reply in the RECORDED bar, or phase 60 counts no fallbacks at all on a
    ## live episode. Point an enabled client at a closed port so both
    ## attempts fail on transport, fast and without a network.
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:9")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "unusable-in-tests")
    let config = fixture(7, bars = 6)
    putEnv("PLAYER_MODEL_TIMEOUT_SECONDS", "5")
    let client = newLlmClient()
    delEnv("PLAYER_MODEL_TIMEOUT_SECONDS")
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    check not client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    let decisions = client.decideAll(sim, seats, @["", "", "", ""],
      @[skNone, skNone, skNone, skNone])
    check decisions.len == Seats
    for index, seat in seats:
      check decisions[index].scripted
      check decisions[index].steps ==
        scriptedAction(sim, seat, skArpeggio).steps
      sim.applyBar(seat, decisions[index].target, decisions[index].steps,
        decisions[index].say, decisions[index].notes,
        decisions[index].scripted)
    var bars = 0
    for event in sim.events:
      if event.kind == evBar:
        bars.inc
        check event.scripted
    check bars == Seats

  test "model replies parse tolerantly and reject the illegal ones":
    let array16 = "[0,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1,-1]"
    let want = @[0, -1, -1, 4, -1, -1, 2, -1, 0, -1, -1, 4, -1, -1, -1, -1]
    check parseDecision(parseJson("""{"target": 2, "steps": """ & array16 &
      "}"), 3).steps == want
    ## A parsed reply is the model's own bar, never a baseline.
    check not parseDecision(parseJson("""{"target": 2, "steps": """ &
      array16 & "}"), 3).scripted
    ## The string form, space- and comma-separated, with every rest spelling.
    check parseDecision(parseJson(
      """{"steps": "0 . r 4 R rest - -1 0 . . 4 . . . ."}"""), 0).steps ==
      @[0, -1, -1, 4, -1, -1, -1, -1, 0, -1, -1, 4, -1, -1, -1, -1]
    check parseDecision(parseJson(
      """{"steps": "0,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1,-1"}"""),
      0).steps == want
    ## Floats are rounded and numeric strings are accepted.
    check parseDecision(parseJson(
      """{"steps": [0.0,-1,-1,3.6,-1,-1,"2",-1,0,-1,-1,4,-1,-1,-1,-1]}"""),
      0).steps == want
    ## A missing target means this turn's new bar.
    check parseDecision(parseJson("""{"steps": """ & array16 & "}"),
      5).target == 5
    check parseDecision(parseJson("""{"target": 2, "steps": """ & array16 &
      "}"), 5).target == 2
    ## Trailing prose after the closing brace is tolerated.
    let messy = extractJsonObject("Sure! {\"target\": 0, \"steps\": " &
      array16 & "} — I kept the tonic on 0 and 8.")
    check parseDecision(messy, 0).steps == want
    ## And the illegal ones are rejected before they touch the sim.
    expect ChorusError:
      discard parseDecision(parseJson(
        """{"steps": [0,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1]}"""), 0)
    expect ChorusError:
      discard parseDecision(parseJson(
        """{"steps": [0,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1,-1,-1]}"""), 0)
    expect ChorusError:
      discard parseDecision(parseJson(
        """{"steps": [14,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1,-1]}"""), 0)
    expect ChorusError:
      discard parseDecision(parseJson(
        """{"steps": [-2,-1,-1,4,-1,-1,2,-1,0,-1,-1,4,-1,-1,-1,-1]}"""), 0)
    expect ChorusError:
      discard parseDecision(parseJson("""{"target": 4, "steps": """ &
        array16 & "}"), 3)
    expect ChorusError:
      discard parseDecision(parseJson("""{"target": 0}"""), 0)
    ## say and notes are capped on RUNE boundaries.
    var long = ""
    for index in 0 ..< 900:
      long.add("音")
    let body = "{\"steps\": " & array16 & ", \"say\": \"" & long &
      "\", \"notes\": \"" & long & "\"}"
    let capped = parseDecision(parseJson(body), 0)
    check capped.say.runeLen == MaxSayLen
    check capped.notes.runeLen == MaxNotesLen
    check capped.say.validateUtf8() == -1
    check capped.notes.validateUtf8() == -1
    check parseScriptKind("1") == skArpeggio
    check parseScriptKind("arpeggio") == skArpeggio
    check parseScriptKind("pedal") == skPedal
    check parseScriptKind("") == skNone
