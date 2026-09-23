## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:chorus-train-bridge tools/train_bridge.nim
## chorus-train-bridge coworld_manifest_template.json [standard|long-form|no-talk]

import std/[json, os]
import chorus/[llm, sim]

const OperatorPrompt = "Raise your own counterfactual credit using the shared chord plan and visible piece."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(view: Sim, seat, id: int): JsonNode =
  %*{
    "kind": "decision", "game": "chorus", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view.turn,
    "semantic_view": {
      "seat": seat, "voice": view.voiceOf[seat], "turn": view.turn,
      "chords": view.chords, "grid": view.grid,
      "score": view.score(seat)
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(view, seat)},
      {"role": "user", "content": userPrompt(view, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {
      "type": "object", "required": ["target", "steps"],
      "properties": {
        "target": {"type": "integer", "minimum": 0, "maximum": MaxBars - 1},
        "steps": {"type": "array", "minItems": Steps, "maxItems": Steps,
          "items": {"type": "integer", "minimum": Rest, "maximum": MaxToken}},
        "say": {"type": "string"}, "notes": {"type": "string"}
      }
    },
    "typed_question": newJNull()
  }

proc encoding(view: Sim, seat, id: int): JsonNode =
  var values = newJArray()
  values.add(%view.turn)
  values.add(%view.config.bars)
  for voice in 0 ..< Voices:
    values.add(%(if view.voiceOf[seat] == voice: 1 else: 0))
  values.add(%view.root)
  values.add(%view.mode)
  values.add(%view.bpm)
  for bar in 0 ..< MaxBars:
    values.add(%(if bar < view.chords.len: view.chords[bar] else: -1))
  for voice in 0 ..< Voices:
    for bar in 0 ..< MaxBars:
      for step in 0 ..< Steps:
        values.add(%(if bar < view.grid[voice].len:
          view.grid[voice][bar][step] else: Rest))
  for other in 0 ..< Seats:
    values.add(%view.score(other))
  var targetChoices = newJArray()
  for target in 0 ..< MaxBars:
    targetChoices.add(if target <= view.turn: %target else: newJNull())
  var heads = newJArray()
  heads.add(%*{"name": "target", "choices": targetChoices})
  for step in 0 ..< Steps:
    var choices = newJArray()
    for token in Rest .. MaxToken:
      choices.add(%token)
    heads.add(%*{"name": "step_" & $step, "choices": choices})
  %*{"decision_id": id, "values": values, "action_heads": heads}

proc actionOf(decision: Decision): JsonNode =
  result = %*{"target": decision.target}
  for step in 0 ..< Steps:
    result["step_" & $step] = %decision.steps[step]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: chorus-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var view: Sim
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      view = game
      id = 0
      response = view.decision(game.pendingSeats()[0], id)
    of "encode":
      doAssert not game.done
      response = view.encoding(game.pendingSeats()[0], id)
    of "teacher":
      doAssert not game.done
      let teacher = view.scriptedAction(game.pendingSeats()[0], skArpeggio)
      response = %*{"response": $actionOf(teacher)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let seat = game.pendingSeats()[0]
      var payload = action
      if not action.hasKey("steps"):
        var steps = newJArray()
        for step in 0 ..< Steps:
          steps.add(action["step_" & $step])
        payload = %*{"target": action["target"], "steps": steps,
          "say": "", "notes": ""}
      let parsed = parseDecision(payload, view.turn)
      game.applyBar(seat, parsed.target, parsed.steps, parsed.say,
        parsed.notes, false)
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson()
        var scores = newJObject()
        var utilities = newJObject()
        for slot in 0 ..< Seats:
          scores[$slot] = outcome["scores"][slot]
          utilities[$slot] = %(outcome["scores"][slot].getFloat() / 100.0)
        observation = %*{"kind": "terminal", "scores": scores,
          "utilities": utilities}
      else:
        if game.turn != view.turn:
          view = game
        observation = view.decision(game.pendingSeats()[0], id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
