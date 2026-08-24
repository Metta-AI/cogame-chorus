## Chorus player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default chorus strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt to Claude every turn.
##
## PLAYER_SCRIPTED=arpeggio (or 1) registers the seat as the built-in
## arpeggio baseline instead; PLAYER_SCRIPTED=pedal as the thin pedal
## baseline. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <chorus-image> --name my-chorus \
##     --run /bin/chorus-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Write musically and earn your seat. Your score is the piece with your voice
minus the piece without it, so every bar has to pay for itself. Land your
onsets on steps 0, 4, 8 and 12 first and use the odd steps sparingly. Play
the chord tones of this bar's chord (r, r+2, r+4) on the strong steps and
pass through neighbours on the weak ones. Move by step wherever you can and
never leap more than an octave. Watch the other voices: if a step already
has three voices sounding, rest; if the grid is thin, add. Keep a motif in
your notes and vary about half of it each bar - repeat nothing exactly and
never start from scratch either. Spend a turn rewriting an early bar only
when the score strip says that bar is the weak one.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "chorus player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "chorus player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send merely queues, so the
  ## game's quit(0) can outrun the flushed final frame. A dead socket is a
  ## normal end of episode, not a player failure: exit 0
  ## (raid 0.1.3 -> 0.1.4).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "chorus player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "chorus player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " (", payload{"voice"}.getStr(), ")"
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "chorus player: final credits ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "chorus player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "chorus player: socket closed by the game (", error.msg,
      "); exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
