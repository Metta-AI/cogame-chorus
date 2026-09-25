## Ordinary Chorus bar choices and scripted baselines shared by game and players.

import std/strutils, sim

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

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"arpeggio" play the arpeggio
  ## bot, "pedal" the pedal bot, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "arpeggio": skArpeggio
  of "pedal", "drone": skPedal
  else: skNone

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
