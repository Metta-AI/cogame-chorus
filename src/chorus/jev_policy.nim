## Jev chooses complete Chorus bar actions from the ordinary seat observation.

import std/[json, os, strutils]
import curly
import policy, sim

proc jevAvailable*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc chooseJevAction*(view: JsonNode, sim: Sim, seat: int): Decision =
  let voice = sim.voiceOf[seat]
  var choices: seq[Decision]
  choices.add(scriptedAction(sim, seat, skArpeggio))
  choices.add(scriptedAction(sim, seat, skPedal))
  var sparse = scriptedAction(sim, seat, skArpeggio)
  for step in 0 ..< Steps:
    if step mod 4 != 0:
      sparse.steps[step] = Rest
  choices.add(sparse)
  var syncopated = scriptedAction(sim, seat, skArpeggio)
  for step in countdown(Steps - 1, 1):
    syncopated.steps[step] = syncopated.steps[step - 1]
  syncopated.steps[0] = Rest
  choices.add(syncopated)
  if sim.turn > 0:
    var rewrite = scriptedAction(sim, seat, skArpeggio)
    rewrite.target = 0
    rewrite.steps = arpeggioBar(sim, voice, 0)
    choices.add(rewrite)
  var criteria = newJObject()
  for i, action in choices:
    criteria[$i] = %*{"target": action.target, "steps": action.steps}
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let endpoint = if sidecar.len > 0: sidecar else:
    getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model = if sidecar.len > 0: "typesafe/jev-1.13" else:
    getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if sidecar.len > 0:
    headers["x-coworld-player-slot"] = $seat
  else:
    headers["authorization"] = "Bearer " & getEnv("TYPESAFE_API_KEY")
  let body = $ %*{
    "model": model,
    "state": "Choose the complete bar action that best improves your " &
      "counterfactual contribution to this shared piece. You control only " &
      "your voice. Observation: " & $view,
    "questions": {"bar": {"type": "choice",
      "instructions": "Choose one legal target and 16-step bar.",
      "criteria": criteria}}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answer = parseJson(response.body)["answers"]["bar"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != choices.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var total = 0.0
  var best = -1.0
  for i in 0 ..< choices.len:
    let probability = probabilities[$i].getFloat()
    if probability < 0 or probability > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += probability
    if probability > best:
      best = probability
      result = choices[i]
  if abs(total - 1) > choices.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  result.scripted = false
  echo "chorus Jev player: chose bar ", result.target,
    " model ", model
