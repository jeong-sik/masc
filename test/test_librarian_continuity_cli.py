"""Hermetic HTTP integration for the synthetic continuity CLI, not a live JEV score."""

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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="masc-continuity-") as temporary:
        root = args.artifacts or Path(temporary)
        root.mkdir(parents=True, exist_ok=True)
        output = root / "report.json"
        requests: list[dict[str, Any]] = []
        generation_texts = [
            "What is the cabinet code?",
            "ORCHID-731",
            "What is the cabinet code?",
            "The information is unavailable.",
            "What is the cabinet code?",
            "ORCHID-731",
        ]
        generation_count = 0
        judge_count = 0

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: Any) -> None:
                pass

            def do_POST(self) -> None:
                nonlocal generation_count, judge_count
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                payload = json.loads(raw)
                report = json.loads(output.read_text())
                requests.append(
                    {
                        "path": self.path,
                        "body": payload,
                        "sha256": hashlib.sha256(raw).hexdigest(),
                        "progress_before_call": [
                            s["progress"][0] for s in report["samples"]
                        ],
                    }
                )
                if self.path == "/judge":
                    judge_count += 1
                    if judge_count == 3:
                        self.reply(503, {"error": "synthetic judge unavailable"})
                    else:
                        question_id = next(iter(payload["questions"]))
                        self.reply(
                            200,
                            {
                                "model": "fixture-jev",
                                "answers": {
                                    question_id: {
                                        "type": "noul",
                                        "noul": 0.875 if judge_count == 1 else 0.0,
                                    }
                                },
                            },
                        )
                    return
                if self.path != "/v1/chat/completions":
                    self.reply(404, {"error": "unknown fixture endpoint"})
                    return
                generation_count += 1
                if generation_count > len(generation_texts):
                    self.reply(
                        400,
                        {
                            "error": {
                                "message": "synthetic question failure",
                                "type": "invalid_request_error",
                            }
                        },
                    )
                    return
                text = generation_texts[generation_count - 1]
                ident = f"fixture-generation-{generation_count}"
                if payload.get("stream"):
                    chunks = [
                        {
                            "id": ident,
                            "model": "fixture-answer-model",
                            "choices": [
                                {
                                    "index": 0,
                                    "delta": {"role": "assistant", "content": text},
                                    "finish_reason": None,
                                }
                            ],
                        },
                        {
                            "id": ident,
                            "model": "fixture-answer-model",
                            "choices": [
                                {"index": 0, "delta": {}, "finish_reason": "stop"}
                            ],
                        },
                    ]
                    body = (
                        "".join(
                            "data: " + json.dumps(chunk) + "\n\n" for chunk in chunks
                        )
                        + "data: [DONE]\n\n"
                    ).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.reply(
                        200,
                        {
                            "id": ident,
                            "model": "fixture-answer-model",
                            "choices": [
                                {
                                    "index": 0,
                                    "message": {"role": "assistant", "content": text},
                                    "finish_reason": "stop",
                                }
                            ],
                        },
                    )

            def reply(self, status: int, payload: dict[str, Any]) -> None:
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_port
        config_source = (
            Path(__file__).resolve().parents[1]
            / "scripts/fixtures/release-evidence/runtime.toml"
        )
        config = root / "runtime.toml"
        config.write_text(
            config_source.read_text()
            .replace("http://127.0.0.1:9/v1", f"http://127.0.0.1:{port}/v1")
            .replace(
                "[models.deepseek-v4-flash]\n",
                "[models.deepseek-v4-flash]\nreasoning-uncontrolled = true\n",
            )
        )
        cases = []
        for ident in ["retained", "absent", "judge-error", "question-error"]:
            cases.append(
                {
                    "id": ident,
                    "source": {
                        "trace_id": "synthetic-original",
                        "turn": 1,
                        "text": "The cabinet code is ORCHID-731.",
                    },
                    "context": {
                        "keeper_name": "synthetic-keeper",
                        "trace_id": "synthetic-current",
                        "read_position": 17,
                        "facts": []
                        if ident == "absent"
                        else [
                            {
                                "id": "memory-1",
                                "claim": "The cabinet code is ORCHID-731.",
                            }
                        ],
                        "unread": "The cabinet is still locked.",
                    },
                }
            )
        dataset = root / "synthetic.json"
        dataset.write_text(json.dumps({"synthetic": True, "cases": cases}))
        env = dict(
            os.environ,
            TYPESAFEAI_API_KEY="synthetic-fixture-key",
            MASC_TYPESAFEAI_ENABLED="true",
            MASC_TYPESAFEAI_ENDPOINT=f"http://127.0.0.1:{port}/judge",
            MASC_TYPESAFEAI_MODEL="fixture-configured-judge",
        )
        command = [
            str(args.binary.resolve()),
            "--input",
            str(dataset),
            "--output",
            str(output),
            "--config",
            str(config),
            "--runtime",
            "ollama_cloud.deepseek-v4-flash",
            "--publish-base-path",
            str(root / "published"),
        ]
        try:
            run = subprocess.run(
                command, env=env, capture_output=True, text=True, timeout=120
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        (root / "stdout.log").write_text(run.stdout)
        (root / "stderr.log").write_text(run.stderr)
        (root / "requests.json").write_text(json.dumps(requests, indent=2))
        assert run.returncode == 1, (run.returncode, run.stdout, run.stderr)
        report = json.loads(output.read_text())
        samples = report["samples"]
        assert [s["progress"][0] for s in samples] == [
            "Scored",
            "Scored",
            "Judge_failed",
            "Question_failed",
        ]
        assert [s["progress"][3]["probability"] for s in samples[:2]] == [0.875, 0.0]
        assert generation_count == 7 and judge_count == 3
        generations = [r for r in requests if r["path"] == "/v1/chat/completions"]
        absent_messages = generations[3]["body"]["messages"]
        assert "ORCHID-731" not in json.dumps(absent_messages), absent_messages
        assert requests[0]["progress_before_call"] == ["Not_started"] * 4
        assert generations[1]["progress_before_call"][0] == "Question_ready"
        assert [r for r in requests if r["path"] == "/judge"][0][
            "progress_before_call"
        ][0] == "Answer_ready"
        for index, sample in enumerate(samples[:3]):
            for offset, generation in enumerate(sample["progress"][1:3]):
                assert generation["response"]["model"] == "fixture-answer-model"
                prepared = generation["request"]["prepared_requests"]
                assert (
                    prepared[-1]["body_sha256"]
                    == generations[index * 2 + offset]["sha256"]
                )
        for index, sample in enumerate(samples[:2]):
            judgment = sample["progress"][3]
            assert judgment["response_model"] == "fixture-jev"
            assert (
                judgment["request_body_sha256"]
                == [r for r in requests if r["path"] == "/judge"][index]["sha256"]
            )
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        blob = root / "published" / ".masc" / "tool_blobs" / digest[:2] / digest
        assert blob.read_bytes() == output.read_bytes()
        print(
            json.dumps(
                {
                    "result": "PASS",
                    "source": "synthetic HTTP fixtures",
                    "samples": 4,
                    "generation_calls": generation_count,
                    "judge_calls": judge_count,
                    "report_sha256": digest,
                    "report": str(output),
                }
            )
        )


if __name__ == "__main__":
    main()
