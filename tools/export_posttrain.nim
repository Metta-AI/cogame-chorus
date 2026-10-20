## Export complete Chorus pieces as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT] [FIRST_PROMPT_SEED]

import std/[json, os, osproc, strutils]
import chorus/[sim, llm]

const OperatorPrompt = "Raise your own counterfactual credit using the shared chord plan and visible piece."
const Variants = ["standard", "long-form", "no-talk"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 5:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [FIRST_PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let mixed = args.len == 5
  let firstPromptSeed = if mixed: parseInt(args[4]) else: 0
  doAssert firstPromptSeed >= 0
  doAssert execProcess("git status --porcelain").strip().len == 0, "commit source before exporting"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for index in 0 ..< games:
    let seed = firstSeed + index
    let partition = ord(seed mod 5 == 0)
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    if mixed:
      runtimeConfig["promptVariant"] = %"mixed"
      runtimeConfig["promptSeed"] = %(firstPromptSeed + wordingCounts[partition])
      inc wordingCounts[partition]
    config.update($runtimeConfig)
    doAssert config.selectedPromptVariant notin {pvHeldoutBriefing, pvHeldoutReference},
      "held-out wording cannot enter a teacher corpus"
    config = sampleEpisode(config)
    var sim = initSim(config)
    let episode = "chorus-" & variant & "-" & $seed &
      (if mixed: "-" & $config.selectedPromptVariant & "-" & $config.promptSeed else: "")
    let family = "chorus-" & $seed
    var rows: seq[string]
    while not sim.done:
      let view = sim
      for seat in view.pendingSeats():
        let teacher = view.scriptedAction(seat, skArpeggio)
        let completion = %*{
          "target": teacher.target, "steps": teacher.steps,
          "say": teacher.say, "notes": teacher.notes
        }
        let parsed = parseDecision(completion, view.turn)
        doAssert parsed.target == teacher.target
        doAssert parsed.steps == teacher.steps
        doAssert parsed.say == teacher.say
        doAssert parsed.notes == teacher.notes
        let system = systemPrompt(view, seat)
        let user = userPrompt(view, seat, OperatorPrompt)
        rows.add($(%*{
          "episode_id": episode,
          "seed": family,
          "decision_id": view.turn * Seats + seat,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "chorus",
          "action_schema_revision": "chorus-bar-v1"
        }))
        sim.applyBar(seat, parsed.target, parsed.steps, parsed.say,
          parsed.notes, true)
    doAssert sim.reason == "complete" and rows.len == config.bars * Seats
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "episode": episode, "prompt_variant": $config.selectedPromptVariant,
      "prompt_seed": config.promptSeed, "decisions": rows.len,
      "scores": outcome["scores"], "piece": outcome["piece"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "prompt_bank": PromptBankVersion,
    "game": "chorus",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-arpeggio",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
