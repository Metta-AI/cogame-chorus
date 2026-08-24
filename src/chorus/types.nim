import std/[json, strutils]

type
  ChorusError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    bars*: int                  ## turns in the episode (4..16, default 8)
    talk*: bool                 ## seats may send one 100-char line a turn
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is
                                ## silent
    sampled*: bool              ## true once the budget cap has been applied
    turnDelayMs*: int
    minTurnSpacingMs*: int      ## floor between LLM batch starts (ms)
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EventKind* = enum
    evStart = "start"
    evTurn = "turn"
    evBar = "bar"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    turn*: int              ## turn/bar: the live turn; end: turnsPlayed;
                            ## start: -1
    seat*: int              ## bar: the seat; -1 otherwise
    voice*: int             ## bar: the seat's voice; -1 otherwise
    target*: int            ## bar: the bar index written; -1 otherwise
    edit*: bool             ## bar: true when target < turn
    steps*: seq[int]        ## bar: the 16 tokens
    say*: string            ## bar: the seat's line ("" when silent)
    scripted*: bool         ## bar: decided by a scripted baseline / fallback
    text*: string           ## bar: the seat's notes after the reply;
                            ## end: reason
    chord*: int             ## turn: this bar's chord-root degree; -1 otherwise
    piece*: float           ## turn: running piece score over bars 0..turn-1
    parts*: array[4, float] ## turn: consonance, leading, rhythm, novelty
    credits*: seq[float]    ## turn: running per-seat credit, by seat

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    bars: 8,
    talk: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    minTurnSpacingMs: 20000,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(ChorusError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("bars"):
    config.bars = node["bars"].getInt()
  if node.hasKey("talk"):
    config.talk = node["talk"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("minTurnSpacingMs"):
    config.minTurnSpacingMs = node["minTurnSpacingMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.bars < 4:
    raise newException(ChorusError, "bars must be at least 4")
  if config.bars > 16:
    raise newException(ChorusError, "bars must be at most 16")
