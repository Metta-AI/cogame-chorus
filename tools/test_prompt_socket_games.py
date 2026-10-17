"""Complete real socket games with scripted seats; records prove prompt intent only."""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import sys

import websockets


async def play(binary, folder, configuration, revision):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = configuration | {"tokens": [str(seat) for seat in range(4)]}
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    ):
        environment.pop(key, None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "prompts.jsonl").as_uri(),
        COWORLD_SOURCE_REVISION=revision,
    )
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(
            binary, env=environment, stdout=log, stderr=log
        )
        players = []
        try:
            async with asyncio.timeout(20):
                while "serving on" not in (folder / "game.log").read_text():
                    assert process.returncode is None, (folder / "game.log").read_text()
                    await asyncio.sleep(0.02)

            async def player(seat):
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}"
                ) as connection:
                    async for raw in connection:
                        frame = json.loads(raw)
                        if frame["type"] == "welcome":
                            assert frame["protocol"] == "chorus.player.v1"
                            await connection.send(
                                json.dumps(
                                    {
                                        "type": "prompt",
                                        "prompt": "",
                                        "scripted": "arpeggio",
                                    }
                                )
                            )
                        elif frame["type"] == "final":
                            assert frame["done"] and frame["reason"] == "complete"
                            return
                        else:
                            assert frame["type"] == "state"
                    raise AssertionError("socket closed before final results")

            players = [asyncio.create_task(player(seat)) for seat in range(4)]
            async with asyncio.timeout(60):
                await asyncio.gather(*players)
                while "artifacts written" not in (folder / "game.log").read_text():
                    assert process.returncode is None
                    await asyncio.sleep(0.02)
            # All artifacts are complete. Skip the unchanged 20-second shutdown grace.
        finally:
            for task in players:
                task.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.terminate()
            await process.wait()
    events = [
        json.loads(line) for line in (folder / "prompts.jsonl").read_text().splitlines()
    ]
    summary = events.pop()
    assert summary["kind"] == "episode" and summary["reason"] == "complete"
    assert summary["source_revision"] == revision
    assert len(events) == summary["records"] == config["bars"] * 4
    systems, users = {}, {}
    for event in events:
        assert event["schema"] == "chorus.prompt-provenance.v1"
        assert (
            event["kind"] == "prompt"
            and event["scope"] == "configured_prompt"
            and event["attempt"] == 0
        )
        metadata = event["prompt_template"]
        assert metadata["bank"] == summary["prompt_bank"] == "chorus-rules-v1"
        assert metadata["variant"] == summary["prompt_variant"]
        assert metadata["selection"] == config["promptVariant"]
        assert metadata["seed"] == summary["prompt_seed"] == config["promptSeed"]
        assert [message["role"] for message in event["messages"]] == ["system", "user"]
        for message in event["messages"]:
            assert (
                metadata[message["role"] + "_sha256"].lower()
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
        system, user = [message["content"] for message in event["messages"]]
        assert systems.setdefault(event["seat"], system) == system
        key = event["turn"], event["seat"]
        assert key not in users
        users[key] = user
    assert set(users) == {
        (turn, seat) for turn in range(config["bars"]) for seat in range(4)
    }
    result = json.loads((folder / "results.json").read_text())
    assert result["reason"] == "complete" and result["scores"] == summary["scores"]
    public = (folder / "replay.json").read_text() + json.dumps(result)
    assert "prompt_template" not in public and "system_sha256" not in public
    return users, result, systems, summary["prompt_variant"]


async def main():
    binary, destination, revision = sys.argv[1:]
    root = Path(destination).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads(
        (
            Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
        ).read_text()
    )
    templates = [
        "canonical",
        "plain",
        "numbered",
        "questions",
        "reordered",
        "heldout-briefing",
        "heldout-reference",
    ]
    reports = []
    for variant in manifest["variants"]:
        for seed in (17, 946001):
            direct = []
            for selection, prompt_seed in [
                *((name, 0) for name in templates),
                *(("mixed", i) for i in range(5)),
            ]:
                name = f"{variant['id']}-{seed}-{selection}-{prompt_seed}"
                run = await play(
                    binary,
                    root / name,
                    variant["game_config"]
                    | {
                        "seed": seed,
                        "turnDelayMs": 0,
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                    },
                    revision,
                )
                if direct:
                    assert run[:2] == direct[0][:2], (
                        "Wording changed visible state or final scores"
                    )
                if selection == "mixed":
                    assert run[2:] == direct[prompt_seed][2:]
                else:
                    assert run[3] == selection
                    direct.append(run)
                reports.append(
                    {"game": name, "decisions": len(run[0]), "selected": run[3]}
                )
            for seat in range(4):
                assert len({run[2][seat] for run in direct}) == 7
    (root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(
        json.dumps(
            {"completed_games": len(reports), "templates": 7, "output": str(root)}
        )
    )


asyncio.run(main())
