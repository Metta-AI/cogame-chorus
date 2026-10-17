## Episode wording and private message hashes, independent of music RNG.
import std/[json, strutils]
import crunchy
import types

const PromptBankVersion* = "chorus-rules-v1"
const ScoringRules* = staticRead("prompts/metric.txt")
const Templates = [
  staticRead("prompts/plain.txt"), staticRead("prompts/numbered.txt"),
  staticRead("prompts/questions.txt"), staticRead("prompts/reordered.txt"),
  staticRead("prompts/heldout-briefing.txt"), staticRead("prompts/heldout-reference.txt")
]

proc renderVariantPrompt*(config: GameConfig, name, voice, others, piece, notation, chords, talk: string): string =
  result = Templates[ord(config.selectedPromptVariant) - 1] %
    [name, voice, others, piece, notation, chords, ScoringRules, talk]
  result.add("\nOUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,\n" &
    "no explanation, no markdown fences, no text before or after the object.\n" &
    "Your reply must begin with the character { and end with }.")

proc promptMetadata*(config: GameConfig, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $config.selectedPromptVariant,
    "selection": $config.promptVariant, "seed": config.promptSeed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}
