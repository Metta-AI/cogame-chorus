"""Export complete teacher games; check exact prompt provenance and seed-family splits."""

import hashlib
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
        assert manifest["wordings_per_family"] == (5 if mixed else 1)
        runs = {run["episode"]: run for run in manifest["runs"]}
        assert len(runs) == (50 if mixed else 10)
        provenance = {}
        for line in (output / "prompt-provenance.jsonl").open():
            row = json.loads(line)
            key = row["episode_id"], row["decision_id"]
            assert key not in provenance
            provenance[key] = row
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
                evidence = provenance[key]
                assert evidence["seed"] == family
                metadata = evidence["prompt_template"]
                assert metadata["bank"] == "chorus-rules-v1"
                assert metadata["variant"] == run["prompt_variant"]
                assert metadata["selection"] == ("mixed" if mixed else "canonical")
                assert metadata["seed"] == run["prompt_seed"]
                assert [message["role"] for message in row["prompt"]] == [
                    "system",
                    "user",
                ]
                for message in row["prompt"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
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
        assert seen == set(provenance)
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
        assert all(wordings == expected for wordings in families.values())
print(
    json.dumps(
        {
            "completed_games": completed,
            "scenario_families": 10,
            "mixed_wordings_per_family": 5,
        }
    )
)
