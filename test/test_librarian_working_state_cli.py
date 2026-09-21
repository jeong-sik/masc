"""Hermetic compare-mode HTTP contract; fixture scores are not live JEV evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


def message(role: str, text: str) -> dict[str, Any]:
    # Agent_core.Checkpoint.message_to_json / Api_common.content_block_to_json.
    return {"role": role, "content": [{"type": "text", "text": text}]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="masc-working-state-") as temporary:
        root = Path(temporary)
        output = root / "report.json"
        requests: list[dict[str, Any]] = []
        generation_count = 0
        judge_count = 0
        summary = "Candidate work state: verify the staged deployment."
        responses = [summary, "baseline answer", "restored answer"] * 2

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: Any) -> None:
                pass

            def reply(self, status: int, payload: dict[str, Any]) -> None:
                self.send_bytes(
                    status, "application/json", json.dumps(payload).encode()
                )

            def send_bytes(self, status: int, mime: str, body: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                nonlocal generation_count, judge_count
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                payload = json.loads(raw)
                requests.append(
                    {
                        "path": self.path,
                        "body": payload,
                        "sha256": hashlib.sha256(raw).hexdigest(),
                    }
                )
                if self.path == "/judge":
                    judge_count += 1
                    if judge_count == 3:
                        self.reply(503, {"error": "synthetic judge unavailable"})
                    else:
                        question_id = next(iter(payload["questions"]))
                        answer = {
                            "type": "noul",
                            "noul": 0.8 if judge_count == 1 else 0.7,
                        }
                        self.reply(
                            200,
                            {"model": "fixture-jev", "answers": {question_id: answer}},
                        )
                    return
                if self.path != "/v1/chat/completions":
                    self.reply(404, {"error": "unexpected fixture endpoint"})
                    return
                generation_count += 1
                if generation_count > len(responses):
                    self.reply(400, {"error": {"message": "unexpected generation"}})
                    return
                text = responses[generation_count - 1]
                base = {"id": f"fixture-{generation_count}", "model": "fixture-model"}
                content = {"role": "assistant", "content": text}
                if payload.get("stream"):
                    choices = [
                        {"index": 0, "delta": content, "finish_reason": None},
                        {"index": 0, "delta": {}, "finish_reason": "stop"},
                    ]
                    body = (
                        "".join(
                            "data: " + json.dumps({**base, "choices": [c]}) + "\n\n"
                            for c in choices
                        )
                        + "data: [DONE]\n\n"
                    )
                    self.send_bytes(200, "text/event-stream", body.encode())
                else:
                    choice = {"index": 0, "message": content, "finish_reason": "stop"}
                    self.reply(200, {**base, "choices": [choice]})

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_port
        fixture = (
            Path(__file__).resolve().parents[1]
            / "scripts/fixtures/release-evidence/runtime.toml"
        )
        config = root / "runtime.toml"
        config.write_text(
            fixture.read_text().replace(
                "http://127.0.0.1:9/v1", f"http://127.0.0.1:{port}/v1"
            )
            + "\n[typesafeai]\n"
            + f'endpoint = "http://127.0.0.1:{port}/judge"\n'
            + 'model = "fixture-configured-judge"\n'
        )
        cases = [
            {
                "id": ident,
                "trace_id": f"synthetic-{ident}",
                "absolute_turn": 1,
                "prefix": [
                    message("user", "PREFIX_ONLY_731 plan the deployment"),
                    message("assistant", "PREFIX_REPLY_732 staging is prepared"),
                ],
                "suffix": [message("user", "FUTURE_ONLY_733 continue the deployment")],
                "facts": [{"id": "fact-1", "claim": "FACT_ONLY_734 use staging"}],
                "question": "QUESTION_ONLY_735 what should happen next?",
            }
            for ident in ["scored", "judge-error"]
        ]
        dataset = root / "dataset.json"
        dataset.write_text(json.dumps({"provenance": ["Synthetic"], "cases": cases}))
        original = dataset.read_bytes()
        command = [
            str(args.binary.resolve()),
            "compare",
            "--input",
            str(dataset),
            "--output",
            str(output),
            "--config",
            str(config),
            "--runtime",
            "ollama_cloud.deepseek-v4-flash",
        ]
        try:
            orphan = Path(
                str(output)
                + ".snapshot-"
                + hashlib.sha256(b"scored").hexdigest()
                + ".json"
            )
            orphan.write_text("existing snapshot must survive")
            refused = subprocess.run(
                command, capture_output=True, text=True, timeout=30
            )
            assert refused.returncode == 2, (refused.returncode, refused.stderr)
            assert orphan.read_text() == "existing snapshot must survive"
            assert not output.exists() and not requests
            orphan.unlink()
            run = subprocess.run(
                command,
                env=dict(os.environ, TYPESAFEAI_API_KEY="fixture-key"),
                capture_output=True,
                text=True,
                timeout=120,
            )
            assert run.returncode == 1, (run.returncode, run.stdout, run.stderr)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        assert dataset.read_bytes() == original
        report = json.loads(output.read_text())
        assert report["schema"] == "masc.librarian-working-state.v1"
        assert report["provenance"] == ["Synthetic"]
        assert generation_count == 6 and judge_count == 4
        generations = [r for r in requests if r["path"] == "/v1/chat/completions"]
        judges = [r for r in requests if r["path"] == "/judge"]
        for index, sample in enumerate(report["samples"]):
            progress = sample["progress"]
            assert progress["work"]["status"] == "ready"
            assert progress["snapshot"]["status"] == "ready"
            snapshot_path = Path(sample["snapshot_path"])
            assert (
                json.loads(snapshot_path.read_text())
                == progress["snapshot"]["artifact"]
            )
            assert progress["snapshot"]["artifact"]["working_state"] == summary
            work_request = progress["work"]["generation"]["request"]
            assert json.loads(work_request["prompt"]["user"]) == {
                "prefix": cases[index]["prefix"]
            }
            assert (
                work_request["prepared_requests"][-1]["body_sha256"]
                == generations[index * 3]["sha256"]
            )
            work = json.dumps(generations[index * 3]["body"]["messages"])
            assert "PREFIX_ONLY_731" in work and "PREFIX_REPLY_732" in work
            assert "QUESTION_ONLY_735" not in work and "FUTURE_ONLY_733" not in work
            assert "FACT_ONLY_734" not in work
            for arm, offset in (("baseline", 1), ("restored", 2)):
                payload = progress[arm][1]
                assert payload["question"] == ["Provided", cases[index]["question"]]
                prompt = json.loads(payload["answer"]["request"]["prompt"]["user"])
                assert prompt["facts"] == cases[index]["facts"]
                assert prompt["question"] == cases[index]["question"]
                assert prompt["working_state"] == (
                    None if arm == "baseline" else summary
                )
                assert prompt["messages"] == (
                    (cases[index]["prefix"] if arm == "baseline" else [])
                    + cases[index]["suffix"]
                )
                assert (
                    payload["answer"]["request"]["prepared_requests"][-1]["body_sha256"]
                    == generations[index * 3 + offset]["sha256"]
                )
                if progress[arm][0] == "Scored":
                    judgment = payload["judgment"]
                    assert judgment["probability"] == (
                        0.8 if index == 0 and arm == "baseline" else 0.7
                    )
                    assert "pass" not in judgment and "passed" not in judgment
                    assert (
                        judgment["request_body_sha256"]
                        == judges[index * 2 + offset - 1]["sha256"]
                    )
            assert progress["restored"][0] == "Scored"
        assert report["samples"][0]["progress"]["baseline"][0] == "Scored"
        failed = report["samples"][1]["progress"]["baseline"]
        assert failed[0] == "Judge_failed"
        assert "503" in failed[1]["failure"]["error"] and "judgment" not in failed[1]
        print(
            json.dumps(
                {
                    "result": "PASS",
                    "source": "synthetic HTTP fixtures",
                    "generation_calls": generation_count,
                    "judge_calls": judge_count,
                }
            )
        )


if __name__ == "__main__":
    main()
