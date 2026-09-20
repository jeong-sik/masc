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
        active_output = output
        requests: list[dict[str, Any]] = []
        generation_texts = [
            "What is the cabinet code?",
            "ORCHID-731",
            "What is the cabinet code?",
            "The information is unavailable.",
            "What is the cabinet code?",
            "ORCHID-731",
            None,
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
                report = json.loads(active_output.read_text())
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
                text = (
                    generation_texts[generation_count - 1]
                    if generation_count <= len(generation_texts)
                    else None
                )
                if text is None:
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
        )
        cases = []
        provided_question = "What is the cabinet code?"
        for ident in [
            "retained",
            "absent",
            "judge-error",
            "question-error",
            "provided",
        ]:
            cases.append(
                {
                    "id": ident,
                    "question": provided_question if ident == "provided" else None,
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
        dataset.write_text(json.dumps({"provenance": ["Synthetic"], "cases": cases}))
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
            (root / "stdout.log").write_text(run.stdout)
            (root / "stderr.log").write_text(run.stderr)
            assert run.returncode == 1, (run.returncode, run.stdout, run.stderr)
            report_bytes = output.read_bytes()
            input_bytes = dataset.read_bytes()
            calls_before_refusals = len(requests)
            rerun = subprocess.run(
                command, env=env, capture_output=True, text=True, timeout=120
            )
            (root / "overwrite-refusal.log").write_text(rerun.stderr)
            assert rerun.returncode == 2, (rerun.returncode, rerun.stderr)
            assert "Output already exists" in rerun.stderr, rerun.stderr
            assert output.read_bytes() == report_bytes
            assert len(requests) == calls_before_refusals
            same_path = list(command)
            same_path[same_path.index("--output") + 1] = str(dataset)
            input_output = subprocess.run(
                same_path, env=env, capture_output=True, text=True, timeout=120
            )
            (root / "input-output-refusal.log").write_text(input_output.stderr)
            assert input_output.returncode == 2, (
                input_output.returncode,
                input_output.stderr,
            )
            assert "--output must differ from --input" in input_output.stderr
            assert dataset.read_bytes() == input_bytes
            assert output.read_bytes() == report_bytes
            assert len(requests) == calls_before_refusals
            refused_runs_model_calls = len(requests) - calls_before_refusals

            # Publication is a view copy: its failure must retain a completed
            # measurement, including a scored zero, in the authoritative file.
            publication_input = root / "publication-input.json"
            publication_input.write_text(
                json.dumps({"provenance": ["Synthetic"], "cases": [cases[-1]]})
            )
            active_output = root / "publication-report.json"
            invalid_store = root / "publication-not-a-directory"
            invalid_store.write_text("A regular file cannot hold the artifact store.")
            generation_texts.append("ORCHID-731")
            publication_command = list(command)
            for option, path in [
                ("--input", publication_input),
                ("--output", active_output),
                ("--publish-base-path", invalid_store),
            ]:
                publication_command[publication_command.index(option) + 1] = str(path)
            publication_run = subprocess.run(
                publication_command,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            (root / "publication-stdout.log").write_text(publication_run.stdout)
            (root / "publication-stderr.log").write_text(publication_run.stderr)
            publication_receipt = json.loads(publication_run.stdout)
            assert publication_run.returncode == 0, (
                publication_run.returncode,
                publication_run.stdout,
                publication_run.stderr,
            )
            assert publication_receipt["all_cases_scored"] is True
            assert publication_receipt["blob_sha256"] is None
            assert publication_receipt["publication_error"]
            publication_bytes = active_output.read_bytes()
            assert (
                publication_receipt["sha256"]
                == hashlib.sha256(publication_bytes).hexdigest()
            )
            publication_progress = json.loads(publication_bytes)["samples"][0][
                "progress"
            ]
            assert publication_progress[0] == "Scored"
            assert publication_progress[1]["judgment"]["probability"] == 0.0
            assert output.read_bytes() == report_bytes
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            (root / "requests.json").write_text(json.dumps(requests, indent=2))
        report = json.loads(output.read_text())
        assert report["schema"] == "masc.librarian-continuity.v1"
        assert report["provenance"] == ["Synthetic"]
        samples = report["samples"]
        assert [s["progress"][0] for s in samples] == [
            "Scored",
            "Scored",
            "Judge_failed",
            "Question_failed",
            "Scored",
        ]
        assert [s["progress"][1]["judgment"]["probability"] for s in samples[:2]] == [
            0.875,
            0.0,
        ]
        assert generation_count == 9 and judge_count == 5
        generations = [r for r in requests if r["path"] == "/v1/chat/completions"]
        absent_messages = generations[3]["body"]["messages"]
        assert "ORCHID-731" not in json.dumps(absent_messages), absent_messages
        assert requests[0]["progress_before_call"] == ["Not_started"] * 5
        assert generations[1]["progress_before_call"][0] == "Question_ready"
        assert [r for r in requests if r["path"] == "/judge"][0][
            "progress_before_call"
        ][0] == "Answer_ready"
        for index, sample in enumerate(samples[:3]):
            progress = sample["progress"][1]
            for offset, role in enumerate(("question", "answer")):
                if role == "question":
                    assert progress[role][0] == "Generated"
                    generation = progress[role][1]
                else:
                    generation = progress[role]
                assert (
                    generation["response"]["text"]
                    == generation_texts[index * 2 + offset]
                )
                assert generation["response"]["model"] == "fixture-answer-model"
                prepared = generation["request"]["prepared_requests"]
                assert (
                    prepared[-1]["body_sha256"]
                    == generations[index * 2 + offset]["sha256"]
                )
        for index, sample in enumerate(samples[:2]):
            judgment = sample["progress"][1]["judgment"]
            assert judgment["request"]["question_id"] == sample["case"]["id"]
            assert judgment["response_model"] == "fixture-jev"
            assert (
                judgment["request_body_sha256"]
                == [r for r in requests if r["path"] == "/judge"][index]["sha256"]
            )
        assert (
            samples[2]["progress"][1]["failure"]["request"]["question_id"]
            == samples[2]["case"]["id"]
        )
        provided = samples[4]["progress"][1]
        assert provided["question"] == ["Provided", provided_question]
        assert provided["answer"]["response"]["text"] == "ORCHID-731"
        assert generations[7]["progress_before_call"][4] == "Question_ready"
        assert (
            provided["answer"]["request"]["prepared_requests"][-1]["body_sha256"]
            == generations[7]["sha256"]
        )
        assert provided["judgment"]["request"]["question"] == provided_question
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        blob = root / "published" / ".masc" / "tool_blobs" / digest[:2] / digest
        assert blob.read_bytes() == output.read_bytes()
        print(
            json.dumps(
                {
                    "result": "PASS",
                    "source": "synthetic HTTP fixtures",
                    "samples": 5,
                    "generation_calls": generation_count,
                    "judge_calls": judge_count,
                    "provided_question_generation_skipped": True,
                    "existing_output_preserved": True,
                    "input_output_same_path_preserved": True,
                    "refused_runs_model_calls": refused_runs_model_calls,
                    "publication_failure_keeps_completed_measurement": True,
                    "report_sha256": digest,
                    "report": str(output),
                }
            )
        )


if __name__ == "__main__":
    main()
