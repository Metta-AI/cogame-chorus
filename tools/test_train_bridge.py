"""Exercise all certified Chorus variants through Metta's decision protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

for variant, bars in (("standard", 8), ("long-form", 10), ("no-talk", 8)):
    with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
        for seed in ("test-1", "test-2"):
            observation = bridge.reset(seed, 4)
            current_turn = -1
            frozen_grid = None
            decisions = 0
            while not isinstance(observation, Terminal):
                if observation.turn != current_turn:
                    current_turn = observation.turn
                    frozen_grid = observation.semantic_view["grid"]
                else:
                    assert observation.semantic_view["grid"] == frozen_grid
                encoding = DecisionEncoding.model_validate_json(bridge.request({"kind": "encode"}))
                assert len(encoding.values) == 1053
                assert encoding.action_sizes == [16] + [15] * 16
                action = json.loads(bridge.teacher())
                assert encoding.action_for(encoding.indices_for(action)) == action
                observation = bridge.step(observation.decision_id, json.dumps(action)).observation
                decisions += 1
            assert decisions == bars * 4
            assert all(abs(observation.utilities[seat] - observation.scores[seat] / 100) < 1e-9 for seat in range(4))
            print(variant, seed, decisions, observation.scores)

with GameBridge([str(BRIDGE), str(MANIFEST), "standard"]) as bridge:
    observation = bridge.reset("text-action", 4)
    while not isinstance(observation, Terminal):
        factorized = json.loads(bridge.teacher())
        canonical = {
            "target": factorized["target"],
            "steps": [factorized[f"step_{step}"] for step in range(16)],
        }
        observation = bridge.step(observation.decision_id, json.dumps(canonical)).observation
    assert len(observation.scores) == 4
