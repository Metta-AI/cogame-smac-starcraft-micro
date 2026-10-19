"""Run complete published Smac games through five players and native HTTP."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from replay_summary import summarise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--variant", choices=("default", "outnumbered", "corridor", "heavy"), default="default")
    parser.add_argument("--wording", default="canonical")
    parser.add_argument("--mode", choices=("accepted", "retry", "fallback"), default="accepted")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    config = next(v["game_config"] for v in manifest["variants"] if v["id"] == args.variant)
    config.update(
        seed=7,
        promptVariant=args.wording,
        promptSeed=4,
        tokens=[f"t{i}" for i in range(5)],
        players=[{"name": f"policy-{i}"} for i in range(5)],
    )
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    (output / "config.json").write_text(json.dumps(config))
    requests, counts = {}, {}
    lock = threading.Lock()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, format, *arguments):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seat = int(self.headers["X-Coworld-Player-Slot"])
            user = body["messages"][0]["content"]
            view, _ = json.JSONDecoder().raw_decode(user[user.index("{") :])
            stage = (view["battle"], view["turn"])
            with lock:
                key = (stage, seat)
                counts[key] = counts.get(key, 0) + 1
                attempt = counts[key]
            call_id = str(uuid5(NAMESPACE_URL, f"smac-{stage}-{seat}-{attempt}"))
            proposal = {
                "note": f"fixture battle {stage[0]} turn {stage[1]} seat {seat}",
                "cogs": [
                    {
                        "id": view["you"]["id"],
                        "intent": "focus",
                        "target": [640, 302],
                        "target_id": view["enemies"][0]["id"] if view["enemies"] else None,
                        "say": "target",
                    }
                ],
            }
            text = json.dumps(proposal)
            if args.mode == "retry" and attempt == 1:
                text = "invalid fixture response"
            status = 429 if args.mode == "fallback" else 200
            response = {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}
            if status == 429:
                response = {"error": {"type": "rate_limit_error", "message": "fixture throttle"}}
            raw = json.dumps(response).encode()
            with lock:
                requests[call_id] = {"seat": seat, "body": body, "raw": raw.decode(), "status": status}
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("X-Coworld-Call-Id", call_id)
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    env = os.environ.copy()
    for key in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "PLAYER_SCRIPTED",
    ):
        env.pop(key, None)
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(output / "config.json").as_uri(),
        COGAME_RESULTS_URI=(output / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(output / "replay.bin").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{provider.server_port}",
        COWORLD_LLM_MODEL="fixture/validation",
        SMAC_HOST_TRACE_PATH=str(output / "host.jsonl"),
        SMAC_SOURCE_REVISION=revision,
    )
    processes, logs = [], []
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        game = subprocess.Popen([str(args.game.resolve())], cwd=root, env=env, stdout=log, stderr=log)
        processes.append(game)
        for _ in range(400):
            assert game.poll() is None
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise RuntimeError("host did not start")
        for seat in range(5):
            player_env = dict(
                env,
                PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Maximize your score.",
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            )
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([str(args.player.resolve())], cwd=root, env=player_env, stdout=log, stderr=log)
            )
        assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
        for player in processes[1:]:
            assert player.wait(timeout=20) == 0
        result = json.loads((output / "results.json").read_text())
        assert result["reason"] == "complete" and result["games"] == config["maxGames"]
        trace = output / "host.jsonl"
        records = [json.loads(line) for line in trace.read_text().splitlines()]
        assert trace.stat().st_mode & 0o777 == 0o600
        assert records[0]["source_revision"] == revision and records[-1]["results"] == result
        decisions = [r for r in records if r["event_type"] == "host_decision"]
        assert {r["battle"] for r in decisions} == {1, 2, 3}
        assert len(decisions) >= 15 and len(decisions) % 5 == 0
        replay = summarise(str(output / "replay.bin"))
        replay_actions = {(r["battle"], r["turn"], r["seat"]): r for r in replay["directives"]}
        for row in decisions:
            record = replay_actions[(row["battle"], row["turn"], row["seat"])]
            assert row["executed_action"] == {"note": record["note"], "cogs": record["cogs"]}
        previous_notes, pending_notes = {}, {}
        current_turn = None
        used = set()
        for row in decisions:
            selected = "reordered" if args.wording == "mixed" else args.wording
            assert row["prompt_configuration"]["variant"] == selected
            assert len(row["attempts"]) == (2 if args.mode == "retry" else 1)
            key = (row["battle"], row["turn"])
            if key != current_turn:
                previous_notes.update(pending_notes)
                pending_notes = {}
                current_turn = key
            view = row["observation"]
            for partner in view["squad"]:
                assert partner["last_note"] == previous_notes.get(partner["id"])
            pending_notes[view["you"]["id"]] = row["executed_action"]["note"]
            for index, attempt in enumerate(row["attempts"]):
                headers = {k.lower(): v for k, v in attempt["response_headers"].items()}
                call_id = headers["x-coworld-call-id"]
                assert call_id not in used
                used.add(call_id)
                receipt = requests[call_id]
                assert receipt["body"] == attempt["request"]["body"] and receipt["seat"] == row["seat"]
                assert receipt["raw"] == attempt["raw_response"] and receipt["status"] == attempt["http_status"]
                assert attempt["prompt"][0]["content"] == receipt["body"]["system"]
                assert attempt["prompt"][1:] == receipt["body"]["messages"]
                for message in attempt["prompt"]:
                    assert (
                        attempt["prompt_configuration"][message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                user = attempt["prompt"][1]["content"]
                sent_view, _ = json.JSONDecoder().raw_decode(user[user.index("{") :])
                assert sent_view == row["observation"]
                for seat in range(5):
                    assert (f"PRIVATE-STRATEGY-{seat}:" in user) == (seat == row["seat"])
                assert attempt["accepted"] == (args.mode == "accepted" or args.mode == "retry" and index == 1)
            if args.mode != "fallback":
                assert row["selected_attempt_id"] and row["action_origin"] == "llm"
                assert row["selected_attempt_id"] == row["attempts"][-1]["attempt_id"]
                assert row["executed_action"] == row["attempts"][-1]["parsed_action"]
            else:
                assert not row["selected_attempt_id"] and row["action_origin"] == "scripted-focusfire"
        assert used == requests.keys() and used
        if args.mode != "fallback":
            assert any(row["selected_attempt_id"] for row in decisions)
        assert b"PRIVATE-STRATEGY-" not in (output / "replay.bin").read_bytes()
        (output / "proof.json").write_text(
            json.dumps(
                {
                    "source_revision": revision,
                    "variant": args.variant,
                    "wording": args.wording,
                    "mode": args.mode,
                    "decisions": len(decisions),
                    "http_requests": len(requests),
                }
            )
        )
        print(output.name, len(decisions), "decisions;", len(requests), "HTTP requests; PASS", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        for log in logs:
            log.close()
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=10)


if __name__ == "__main__":
    main()
