## Chorus player: receives its private observation and returns a complete bar.

import std/[json, options, os, strutils]
import whisky
import chorus/[llm, policy_view, jev_policy, sim]

const DefaultPrompt = """
Write musically and earn your seat. Your score is the piece with your voice
minus the piece without it. Land onsets on steps 0, 4, 8 and 12 first.
Play chord tones on strong steps and pass through neighbours on weak ones.
Watch the other voices: rest when a step already has three voices sounding.
Keep a motif in your private notes and vary it across bars.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT", DefaultPrompt)
  let scripted = parseScriptKind(getEnv("PLAYER_SCRIPTED"))
  let jev = getEnv("PLAYER_POLICY").strip().toLowerAscii() == "jev"
  let client = if scripted == skNone and not jev: newLlmClient() else: nil
  echo "chorus player: connecting to game"
  let socket = newWebSocket(url)
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      let payload = parseJson(message.data)
      case payload["type"].getStr()
      of "welcome":
        echo "chorus player: seated at slot ", payload["slot"].getInt()
      of "turn":
        let view = payload["view"]
        let sim = simFromSeatView(view)
        let seat = view["slot"].getInt()
        var decision: Decision
        if jev:
          decision = chooseJevAction(view, sim, seat)
        elif scripted != skNone:
          decision = scriptedAction(sim, seat, scripted)
        else:
          var prompts = newSeq[string](Seats)
          var scripts = newSeq[ScriptKind](Seats)
          prompts[seat] = prompt
          decision = client.decideAll(sim, @[seat], prompts, scripts)[0]
        socket.send($ %*{
          "type": "decision", "id": payload["id"],
          "action": {"target": decision.target, "steps": decision.steps,
            "say": decision.say, "notes": decision.notes,
            "scripted": decision.scripted}
        })
      of "final":
        echo "chorus player: final credits ", payload["scores"]
        break
      else:
        discard
  except CatchableError as error:
    echo "chorus player: socket closed by the game (", error.msg, ")"
  socket.close()
