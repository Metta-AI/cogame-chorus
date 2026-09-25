## The ordinary seat observation. It includes the public score inputs and
## chord plan, plus this seat's notebook. Other seats' notes and credits stay
## in the game.

import std/json, sim

proc seatViewJson*(sim: Sim, slot: int, started: bool): JsonNode =
  let voice = sim.voiceOf[slot]
  var bars = newJArray()
  for bar in sim.grid[voice]:
    bars.add(%bar)
  let parts = sim.pieceScore(sim.grid, sim.turnsPlayed)
  %*{
    "type": "state",
    "slot": slot,
    "name": sim.names[slot],
    "voice": VoiceNames[voice],
    "seat": {
      "voice": voice,
      "voiceName": VoiceNames[voice],
      "base": sim.baseMidi(voice),
      "score": round6(sim.score(slot)),
      "onsets": sim.onsetsOf(voice, sim.turnsPlayed),
      "bars": bars,
      "notes": sim.notes[slot]
    },
    "piece": round6(parts.piece),
    "turn": sim.turn,
    "turns": sim.config.bars,
    "turnsPlayed": sim.turnsPlayed,
    "started": started,
    "done": sim.done,
    "reason": sim.reason,
    "talk": sim.config.talk,
    "aliases": sim.names,
    "voiceOf": sim.voiceOf,
    "root": sim.root,
    "rootName": sim.rootName,
    "modeIndex": sim.mode,
    "bpm": sim.bpm,
    "chords": sim.chords,
    "grid": sim.grid,
    "heard": sim.heard,
    "legalTargets": sim.legalTargets()
  }

proc simFromSeatView*(view: JsonNode): Sim =
  ## Rebuild only the fields that an ordinary policy uses. The observation
  ## carries no other seat's private notes or credits.
  result.config = GameConfig(bars: view["turns"].getInt(), talk: view["talk"].getBool())
  for name in view["aliases"]:
    result.names.add(name.getStr())
  for seat in 0 ..< Seats:
    let voice = view["voiceOf"][seat].getInt()
    result.voiceOf[seat] = voice
    result.seatOf[voice] = seat
  result.root = view["root"].getInt()
  result.rootName = view["rootName"].getStr()
  result.mode = view["modeIndex"].getInt()
  result.bpm = view["bpm"].getInt()
  for chord in view["chords"]:
    result.chords.add(chord.getInt())
  for voice in 0 ..< Seats:
    let voiceGrid = view["grid"][voice]
    for bar in voiceGrid:
      var steps: Bar
      for index in 0 ..< Steps:
        steps[index] = bar[index].getInt()
      result.grid[voice].add(steps)
  for voice in 0 ..< Seats:
    result.heard[voice] = view["heard"][voice].getStr()
  result.notes = newSeq[string](Seats)
  result.notes[view["slot"].getInt()] = view["seat"]["notes"].getStr()
  result.turn = view["turn"].getInt()
  result.turnsPlayed = view["turnsPlayed"].getInt()
