"""Play complete three-battle games, preserving simultaneous information across wordings."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

WORDINGS = ("canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference")


def play(binary: Path, manifest: Path, variant: str, wording: str, prompt_seed: int, seed: int) -> str:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )
    input_stream, output_stream = process.stdin, process.stdout
    assert input_stream is not None and output_stream is not None
    digest = hashlib.sha256()

    def request(value: dict) -> dict:
        input_stream.write(json.dumps(value) + "\n")
        input_stream.flush()
        return json.loads(output_stream.readline())

    def record(value: dict) -> None:
        digest.update(json.dumps(value, sort_keys=True).encode())

    try:
        observation = request(
            {
                "kind": "reset",
                "players": 5,
                "seed": f"smac-{seed}",
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "validation",
            }
        )
        selected = WORDINGS[prompt_seed % 5] if wording == "mixed" else wording
        system_seen = None
        battles = set()
        decisions = 0
        previous_notes, pending_notes = {}, {}
        current_turn = None
        while observation["kind"] == "decision":
            view = observation["semantic_view"]
            system, user = [message["content"] for message in observation["messages"]]
            assert view.pop("prompt_template") == {
                "bank": "smac-starcraft-micro-rules-v1",
                "selection": wording,
                "variant": selected,
                "seed": prompt_seed,
                "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
            }
            if system_seen is None:
                system_seen = system
            assert system == system_seen
            assert not {"seed", "rng", "policies", "prompt"} & view.keys()
            key = (view["battle"], view["turn"])
            if key != current_turn:
                previous_notes.update(pending_notes)
                pending_notes = {}
                current_turn = key
            for partner in view["squad"]:
                assert partner["last_note"] == previous_notes.get(partner["id"])
            battles.add(view["battle"])
            observation["messages"][0]["content"] = system[system.index("Your whole squad") :]
            record(observation)
            proposal = json.loads(request({"kind": "teacher"})["response"])
            proposal["note"] = f"battle {view['battle']} turn {view['turn']} seat {observation['seat']}"
            record(proposal)
            response = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(proposal)}
            )
            assert response["kind"] == "accepted"
            pending_notes[view["you"]["id"]] = response["action"]["note"]
            record(response["action"])
            observation = response["observation"]
            decisions += 1
            assert decisions <= 200
        assert observation["kind"] == "terminal" and battles == {1, 2, 3}
        assert decisions % 5 == 0 and decisions >= 15
        assert set(observation["scores"]) == {str(i) for i in range(5)}
        record(observation)
        return digest.hexdigest()
    finally:
        input_stream.close()
        output_stream.close()
        assert process.wait(timeout=10) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
    for variant in ("default", "outnumbered", "corridor", "heavy"):
        for seed in (17, 946001):
            reference = play(args.binary, manifest, variant, "canonical", 0, seed)
            for wording, prompt_seed in [(w, 0) for w in WORDINGS[1:]] + [("mixed", i) for i in range(5)]:
                assert play(args.binary, manifest, variant, wording, prompt_seed, seed) == reference
        print(variant, "24 complete games PASS", flush=True)
    for wording in WORDINGS[-2:]:
        rejected = subprocess.run(
            [str(args.binary), str(manifest), "default"],
            input=json.dumps({"kind": "reset", "players": 5, "seed": "guard", "promptVariant": wording}) + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        assert rejected.returncode != 0 and "held-out wording cannot enter training" in rejected.stderr
    print("96 complete games and held-out exclusion PASS", flush=True)


if __name__ == "__main__":
    main()
