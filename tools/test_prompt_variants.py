"""Complete Chorus bridge games, including rewrites, across all certified variants."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
templates = ["canonical", "plain", "numbered", "questions", "reordered"]
completed = 0


def request(process, value):
    process.stdin.write(json.dumps(value) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


for variant in json.loads(manifest.read_text())["variants"]:
    name = variant["id"]
    command = [binary, str(manifest), name, "--language"]
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )
    try:
        for seed in ("prompt-17", "prompt-946001"):
            canonical = None
            direct = []
            for selection, prompt_seed in [
                *((name, 0) for name in templates),
                *(("mixed", i) for i in range(5)),
            ]:
                selected = templates[prompt_seed] if selection == "mixed" else selection
                observation = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 4,
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                    },
                )
                transcript = []
                systems = {}
                while observation["kind"] == "decision":
                    view = observation["semantic_view"]
                    metadata = view.pop("prompt_template")
                    assert metadata["bank"] == "chorus-rules-v1"
                    assert (
                        metadata["selection"],
                        metadata["seed"],
                        metadata["variant"],
                    ) == (selection, prompt_seed, selected)
                    messages = observation["messages"]
                    assert [message["role"] for message in messages] == [
                        "system",
                        "user",
                    ]
                    for message in messages:
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    seat = observation["seat"]
                    assert (
                        systems.setdefault(seat, messages[0]["content"])
                        == messages[0]["content"]
                    )
                    assert observation["inference_mode"] == "text_action"
                    for other in range(4):
                        if other != seat:
                            assert (
                                f"PRIVATE-NOTES-{other}" not in messages[1]["content"]
                            )
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    assert len(action["steps"]) == 16 and "step_0" not in action
                    if observation["turn"] % 3 == 2:
                        action["target"] = observation["turn"] - 1
                    action["notes"] = f"PRIVATE-NOTES-{seat}"
                    action["say"] = (
                        f"voice {seat}" if variant["game_config"]["talk"] else ""
                    )
                    transcript.append((view, messages[1], action))
                    result = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": observation["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert result["kind"] == "accepted" and result["action"] == action
                    observation = result["observation"]
                    assert len(transcript) <= variant["game_config"]["bars"] * 4
                assert (
                    observation["kind"] == "terminal"
                    and len(transcript) == variant["game_config"]["bars"] * 4
                )
                outcome = transcript, observation
                if selection == "canonical":
                    canonical = outcome
                else:
                    assert outcome == canonical, (
                        "Wording changed state, user messages, actions, or scores"
                    )
                if selection == "mixed":
                    assert systems == direct[prompt_seed]
                else:
                    direct.append(systems)
                completed += 1
            for seat in range(4):
                assert len({system[seat] for system in direct}) == 5
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    for invalid in (
        {"promptVariant": "heldout-briefing"},
        {"promptVariant": "heldout-reference"},
        {"promptVariant": "mixed"},
        {"promptVariant": "mixed", "promptSeed": -1},
        {"promptVariant": "mixed", "promptSeed": True},
    ):
        result = subprocess.run(
            command,
            input=json.dumps(
                {"kind": "reset", "seed": "invalid", "players": 4} | invalid
            )
            + "\n",
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout

comparisons = 0
if len(sys.argv) == 3:
    baseline = str(Path(sys.argv[2]).resolve())
    for variant in json.loads(manifest.read_text())["variants"]:
        processes = [
            subprocess.Popen(
                [program, str(manifest), variant["id"]],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            for program in (baseline, binary)
        ]
        try:
            for seed in ("prompt-17", "prompt-946001"):
                observations = [
                    request(process, {"kind": "reset", "seed": seed, "players": 4})
                    for process in processes
                ]
                while observations[0]["kind"] == "decision":
                    observations[1]["semantic_view"].pop("prompt_template")
                    assert observations[1].pop("inference_mode") is None
                    assert observations[0] == observations[1], (
                        "Canonical bytes changed from the original game"
                    )
                    actions = [
                        request(process, {"kind": "teacher"})["response"]
                        for process in processes
                    ]
                    assert actions[0] == actions[1]
                    results = [
                        request(
                            process,
                            {
                                "kind": "step",
                                "decision_id": observation["decision_id"],
                                "response": action,
                            },
                        )
                        for process, observation, action in zip(
                            processes, observations, actions, strict=True
                        )
                    ]
                    observations = [result["observation"] for result in results]
                assert observations[0] == observations[1]
                comparisons += 1
        finally:
            for process in processes:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
print(
    json.dumps(
        {
            "complete_language_games": completed,
            "canonical_baseline_comparisons": comparisons,
        }
    )
)
