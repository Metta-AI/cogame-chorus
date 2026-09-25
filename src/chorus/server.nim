## Chorus game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - the chorus stage renderer
##   GET /client/chrome_common.js    - the inherited chrome module
##   GET /client/chrome.css          - the inherited chrome stylesheet
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player observation/action protocol
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (chorus.player.v2), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"voice":...}
##                   {"type":"state",...} after every event (redacted to the
##                   seat's own voice, its own credit and the shared piece
##                   score)
##                   {"type":"turn","id":N,"view":{...}} for each action
##                   {"type":"final","scores":[...],"voices":[...]}
##   player -> game: {"type":"decision","id":N,"action":{target,steps,
##                    say,notes,scripted}}

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  policy,
  policy_view,
  sim

const
  ReplayVersion = 1
  ## After the artifacts are written the server keeps answering /healthz and
  ## /global for this long before exiting: the episode runner pings /global
  ## AFTER the player pods start, and a short certification episode would
  ## otherwise already be gone (lantern 0.1.3 -> 0.1.4).
  ShutdownGraceSeconds = 20

type
  GameState = object
    config: GameConfig
    sim: Sim
    replies: Table[int, JsonNode]
    requestId: int
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"chorus"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.sim.seatViewJson(slot, gs.started))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "chorus.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "bars": gs.config.bars,
      "steps": Steps,
      "seed": gs.config.seed,
      "talk": gs.config.talk,
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "voices": results["voices"],
      "names": aliasNames,
      "piece": results["piece"],
      "bars": results["bars"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "chorus: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Bounded shutdown grace: /healthz and /global keep answering while the
  ## runner finishes its post-start probes, then the process exits.
  echo "chorus: artifacts written; holding the server up for ",
    ShutdownGraceSeconds, "s before exit"
  sleep(ShutdownGraceSeconds * 1000)
  echo "chorus: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "chorus: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    ## The platform kills the episode at its timeout and keeps nothing.
    ## Play inside a fraction of it so results and the replay are written
    ## with room to spare. The hosted dispatcher hands the timeout only to
    ## its own worker sidecar, NOT to the game container, so when the env is
    ## silent assume the configured platform default rather than playing
    ## open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "chorus: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and epochTime() > playDeadline:
          ## The platform kills an episode that outruns its timeout and
          ## keeps nothing at all, so give up bars rather than the whole
          ## result: stop here, between turns.
          echo "chorus: episode deadline reached after ",
            state.sim.turnsPlayed, "/", config.bars, " bars; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        echo "chorus: turn ", state.sim.turn, " of ", config.bars,
          " at ", (epochTime() - gameStart).int, "s"

      ## Each player gets its own observation from the same pre-action state.
      ## The response queue is keyed by this turn's request id, so late
      ## decisions can never affect the next turn.
      withLock stateLock:
        state.requestId = simCopy.turn + 1
        state.replies.clear()
        for seat in seats:
          if state.playerSockets.hasKey(seat):
            state.playerSockets[seat].send($ %*{
              "type": "turn",
              "id": state.requestId,
              "view": simCopy.seatViewJson(seat, true)
            })

      let turnDeadline = if playDeadline > 0.0:
        min(epochTime() + config.turnResponseTimeoutSeconds.float, playDeadline)
      else:
        epochTime() + config.turnResponseTimeoutSeconds.float
      while epochTime() < turnDeadline:
        var complete = false
        withLock stateLock:
          complete = state.replies.len >= seats.len
        if complete:
          break
        sleep(25)

      withLock stateLock:
        for seat in seats:
          try:
            if not state.replies.hasKey(seat):
              raise newException(ChorusError, "player reply timed out")
            let action = state.replies[seat]["action"]
            var decision = Decision(
              target: action["target"].getInt(),
              say: action{"say"}.getStr(),
              notes: action{"notes"}.getStr(),
              scripted: action{"scripted"}.getBool()
            )
            for step in action["steps"]:
              decision.steps.add(step.getInt())
            echo "chorus: turn ", state.sim.turn, " ", state.sim.names[seat],
              " (", state.sim.voiceName(seat), ") writes bar ",
              decision.target,
              (if decision.say.len > 0: " says \"" & decision.say & "\""
               else: ""),
              " at ", (epochTime() - gameStart).int, "s"
            state.sim.applyBar(seat, decision.target, decision.steps,
              decision.say, decision.notes, decision.scripted)
          except CatchableError as error:
            echo "chorus: reply rejected (", error.msg,
              "); using the arpeggio fallback"
            let fallback = scriptedAction(state.sim, seat, skArpeggio)
            state.sim.applyBar(seat, fallback.target, fallback.steps, "", "",
              true)
        state.broadcastLocked()

      ## Pace between turns so spectators can read the bar that just landed.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    ## Let the last bar land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc scriptHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(
        request, clientDir() / name,
        "application/javascript; charset=utf-8"
      )
  handler

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "chorus: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      let voice = state.sim.voiceOf[slot]
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "chorus.player.v2",
        "slot": slot,
        "name": state.sim.names[slot],
        "voice": VoiceNames[voice],
        "base": state.sim.baseMidi(voice),
        "bars": state.config.bars,
        "steps": Steps,
        "key": state.sim.rootName,
        "mode": ModeNames[state.sim.mode],
        "bpm": state.sim.bpm
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload["type"].getStr() == "decision":
          withLock stateLock:
            if state.started and not state.finished and
                payload["id"].getInt() == state.requestId and
                not state.replies.hasKey(slot):
              state.replies[slot] = payload
      except CatchableError as error:
        echo "chorus: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## Every real route is registered BEFORE the catch-all asset route: the
  ## certifier probes /client/player and /client/global before the player
  ## pods start, and a 404 there is a game_contract_violation.
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/renderer.js", scriptHandler("renderer.js"))
  result.get("/client/chrome_common.js", scriptHandler("chrome_common.js"))
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.bars = payload["config"]{"bars"}.getInt(8)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.talk = payload["config"]{"talk"}.getBool(true)
  ## The replay carries the episode's fitted cap; never re-fit it. Voices,
  ## key, mode, tempo and the chord plan are re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("chorus.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "chorus: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(ChorusError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.replies = initTable[int, JsonNode]()
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "chorus: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
