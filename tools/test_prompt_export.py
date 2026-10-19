"""Export complete teacher games; check wording selection and seed-family splits."""

import json
from pathlib import Path
import subprocess
import sys

binary, destination = sys.argv[1:]
root = Path(destination).resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=False)
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
completed = 0
for variant, bars in (("standard", 8), ("long-form", 10), ("no-talk", 8)):
    canonical = {}
    for mixed in (False, True):
        output = root / f"{variant}-{'mixed' if mixed else 'canonical'}"
        command = [binary, str(output), "10", "1", variant]
        if mixed:
            command.append("0")
        subprocess.run(command, check=True, timeout=90)
        manifest = json.loads((output / "manifest.json").read_text())
        assert (
            manifest["source_revision"] == revision
            and manifest["prompt_bank"] == "chorus-rules-v1"
        )
        runs = {run["episode"]: run for run in manifest["runs"]}
        assert len(runs) == 10
        splits, trajectories = {}, {}
        seen = set()
        for split in ("train", "validation"):
            families = set()
            count = 0
            for line in (output / f"{split}.jsonl").open():
                row = json.loads(line)
                episode = row["episode_id"]
                run = runs[episode]
                family = f"chorus-{run['seed']}"
                assert row["seed"] == family
                assert (run["seed"] % 5 == 0) == (split == "validation")
                key = episode, row["decision_id"]
                assert key not in seen
                seen.add(key)
                assert [message["role"] for message in row["prompt"]] == [
                    "system",
                    "user",
                ]
                assert row["completion"][0]["role"] == "assistant"
                action = json.loads(row["completion"][0]["content"])
                assert len(action["steps"]) == 16 and "step_0" not in action
                assert (
                    row["game"] == "chorus"
                    and row["action_schema_revision"] == "chorus-bar-v1"
                )
                trajectories.setdefault(episode, []).append(
                    (row["decision_id"], row["prompt"][1], action)
                )
                families.add(family)
                count += 1
            assert count == manifest[split + "_examples"]
            splits[split] = families
        assert len(splits["train"]) == 8 and len(splits["validation"]) == 2
        assert splits["train"].isdisjoint(splits["validation"])
        families = {}
        for episode, run in runs.items():
            assert len(trajectories[episode]) == run["decisions"] == bars * 4
            outcome = trajectories[episode], run["scores"], run["piece"]
            if mixed:
                assert outcome == canonical[run["seed"]], (
                    "Wording changed a complete teacher game"
                )
            else:
                canonical[run["seed"]] = outcome
            families.setdefault(run["seed"], set()).add(run["prompt_variant"])
            completed += 1
        expected = (
            {"canonical", "plain", "numbered", "questions", "reordered"}
            if mixed
            else {"canonical"}
        )
        assert set().union(*families.values()) == expected
        assert all(len(wordings) == 1 for wordings in families.values())
print(
    json.dumps(
        {
            "completed_games": completed,
            "scenario_families": 10,
        }
    )
)
