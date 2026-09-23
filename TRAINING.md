# Metta post-training data

The native simulator and published `arpeggio` policy export supervised
examples for all three certified Chorus variants:

```sh
nimby sync nimby.lock
for variant in standard long-form no-talk; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/chorus-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
pieces. The exporter freezes the game state at each simultaneous turn, then
records each seat's hosted system and user prompts and an `arpeggio` bar
accepted by the game's reply parser. Parsed bars drive the simulator. Whole
pieces stay in one split. The manifest records source revision, variant,
scores, piece score, and row counts. Existing output directories are never
overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/chorus-standard \
  --output /tmp/chorus-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete pieces per variant yielded 1,040 examples. Every example fit
the Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 3,125.
One CPU optimizer step per variant with a local tiny model verifies the Metta
post-training path. These examples distill the scripted teacher; they do not
establish stronger league play.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/chorus-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/chorus-train-bridge
```

All three certified variants use four seats, 1,053 numeric observation values,
and 17 independent action heads: a masked target bar (16 choices) and 16
note tokens (15 choices each). Numeric observations contain only the public
piece, chord plan, and counterfactual credits. All seats in the same turn see
the same frozen piece. The published `arpeggio` baseline supplies opponents
and teacher labels. Terminal rewards use the game's own signed credit divided
by 100, within the shared [-1, 1] utility range. Text messages retain the
hosted prompts for Metta post-training.
