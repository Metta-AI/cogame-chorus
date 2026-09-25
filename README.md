# Chorus

Four cogs write one piece of music together on a 16-step sequencer.

Each seat owns one **voice** — Bass, Tenor, Alto or Soprano — and the seat-to-voice assignment is a
seeded permutation, redrawn every episode, so no policy can specialise on one register. The key, the
mode, the tempo and a bar-by-bar chord plan are drawn from the same seed and revealed to everybody
from turn 0. Every turn all four cogs write one bar **at the same time**, without seeing each
other's choice: either the new bar, or a rewrite of one of their own earlier bars — and a rewrite
spends the turn, because the new bar merely holds a copy of the last one. A bar is 16 integer
tokens: `-1` is a rest and `0..13` is a scale degree in that voice's two-octave register; every note
lasts exactly one step.

When the piece is finished a fixed, public, deterministic metric scores it out of 100 — consonance
35 %, voice leading 25 %, rhythmic coherence 25 %, novelty against your own earlier bars 15 % — and
**each seat's score is a counterfactual**: the piece as written, minus the piece with every note of
that seat's voice deleted. There is no vote and nobody judges anybody, so there is nothing to
collude on. The only way to raise your score is to raise the piece by more than your absence would,
and a voice that is rougher than the piece's average, or that fills the grid until all four voices
sound at once, scores **below zero**. Credits are leave-one-out differences and do *not* sum to the
piece score.

Each player receives its own observation and returns a complete bar action. Prompt, Jev, and
scripted policies run in player containers. The game validates simultaneous replies, applies a
scripted fallback for missing or invalid actions, and records the replay.

## Layout

| path | what it is |
|---|---|
| `src/chorus/types.nim` | the config and the event record |
| `src/chorus/sim.nim` | the pure rules and the metric — no IO, no networking, no LLM. The server, the tests and the wasm viewer all drive this same module |
| `src/chorus/llm.nim` | player-side prompt building and Claude decision parsing |
| `src/chorus/jev_policy.nim` | player-side Jev choice over complete bar actions |
| `src/chorus/policy.nim` | shared scripted baselines and action type |
| `src/chorus/policy_view.nim` | private seat observation and player-side simulation view |
| `src/chorus/server.nim` | the Coworld game contract: HTTP routes, the player and spectator websockets, the turn loop |
| `src/chorus.nim` | the game entrypoint (`/bin/chorus`) |
| `src/chorus_player.nim` | the player entrypoint (`/bin/chorus-player`) |
| `client/chrome.css` | `cogame-bullwhip`'s broadcast chrome, unchanged, with one appended chorus block |
| `client/chrome_common.js` | the chrome half of `cogame-bullwhip`'s `renderer.js`, copied character for character, plus one added function `relayout()` |
| `client/renderer.js` | the chorus stage: the sequencer piano roll, the chord ribbon, the playhead, the score strip, the feed, the endcard and the WebAudio playback |
| `client/global.html` / `player.html` / `replay_broadcast.html` | the starter's pages with the chorus game block appended |
| `replay-viewer/` | the static wasm replay bundle: `chorus_replay.nim` compiles `src/chorus/sim.nim` to WebAssembly so a browser re-derives every frame from the replay bytes alone |
| `tools/build_replay_viewer.sh` | the `coworld build` hook that produces that bundle (committed executable) |
| `tools/ci/` | the raw-docker episode smoke, the headless-browser viewer smoke, and the policy set |
| `tests/` | sim unit tests and the scripted-baseline tests |
| `docs/plans/` | the accepted design note |

## The local loop

The repo builds and runs entirely in Docker; CI is the harness.

```bash
docker build --platform=linux/amd64 -t coworld-chorus:ci .
./tools/ci/docker_smoke.sh coworld-chorus:ci      # one real episode, four seats
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs \
  --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 10
```

Nim tests, with a `nimby`-synced package tree:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --hints:off --path:src tests/test_sim.nim
nim r --hints:off -d:release --path:src tests/test_bot.nim
```

Watch a live episode at `http://localhost:8080/client/global`, and a recorded one at
`/client/replay` or in the static bundle at `index.html?replay=<url>`.

## Fielding a policy

Reuse the published image and set `PLAYER_PROMPT` to your strategy. Model credentials must be
available to the player container:

```bash
coworld upload-policy coworld-chorus:latest \
  --name my-chorus --run /bin/chorus-player \
  --secret-env PLAYER_PROMPT="Own one voice. Put your onsets on steps 0, 4, 8 and 12, play the
chord tones of this bar's chord on the strong steps, move by step, and change about half your
motif each bar. Rest on any step where three voices already sound."
```

Two scripted baselines ship in the same image and are selected with `PLAYER_SCRIPTED`:

Set `PLAYER_POLICY=jev` to let Jev choose among complete bar actions from the private seat
observation. The player uses its Bedrock sidecar or `TYPESAFE_API_KEY` and `TYPESAFE_BASE_URL`.

| value | baseline |
|---|---|
| `arpeggio` (or `1` / `true` / `yes`) | chord tones spread across the four voices on complementary steps, rotated a place each bar. The strong baseline, and the fallback for any seat whose reply fails twice. |
| `pedal` | the chord root on the downbeat and a fifth halfway through the odd bars. Always legal, far too thin to score. |

They also play **every** seat when no LLM credentials are present, so an episode always completes
and offline certification finishes in seconds.

## The rules, in one screen

- 4 seats, 4 voices (`Bass` 36, `Tenor` 48, `Alto` 60, `Soprano` 72), seeded permutation.
- `bars` turns (default 8, range 4–16); every bar is 16 steps.
- `target` must satisfy `0 ≤ target ≤ turn` and is required in the player action.
- `steps` is exactly 16 integer tokens, each `-1` or `0..13`. The prompt player accepts
  flexible model output and sends a canonical action to the game.
- `say` is one 100-rune line all three other cogs read next turn (talk variants only); `notes` is a
  600-rune private notebook fed back verbatim.
- Two endings and no others: `complete` (all bars written) and `deadline` (the play deadline was
  crossed between turns; the piece is honestly scored on the bars actually written).

Full rules and the metric with worked examples are in the manifest's `rules.md` and `scoring.md`
pages, and the design note is at `docs/plans/2026-08-24-chorus-design.md`.
