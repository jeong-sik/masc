"""Exercise the CLI's real HTTP/MCP capture boundary with explicit fixtures."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import http.server
import json
import os
import pathlib
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from unittest import mock
from collections.abc import Iterator
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/harness/workload/keeper_temporal_continuity.py"


@contextlib.contextmanager
def fixture(
    workspace: pathlib.Path, variation: str
) -> Iterator[tuple[str, list[dict[str, Any]]]]:
    calls: list[dict[str, Any]] = []
    message: dict[str, Any] = {
        "role": "user",
        "origin": "agent_instruction",
        "metadata": {"masc.librarian_working_state.v1": True},
        "content_blocks": [{"type": "text", "text": "A valid constraint survives."}],
    }
    if variation == "prose-only":
        message.pop("metadata")
        message["content_blocks"] = [
            {"type": "text", "text": "[Librarian working state] I claim continuity."}
        ]
    raw = json.dumps(message, ensure_ascii=False).encode()
    part = {
        "index": 0,
        "kind": "message",
        "role": "user",
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }
    operation: dict[str, Any] = {
        "schema": "masc.keeper_chat_operation.v1",
        "operation_id": "op-1",
        "state": "Succeeded",
        "outcome_ref": "trace#1",
        "completed_reply": {
            "status": "available",
            "turn_ref": "trace#1",
            "replies": [
                {
                    "message_id": "reply-1",
                    "text": "Continue the read-only investigation.",
                }
            ],
        },
    }
    if variation == "reply-unavailable":
        operation["completed_reply"] = {
            "status": "unavailable",
            "reason": "not_retained",
        }
    if variation == "wrong-reply-turn":
        operation["completed_reply"]["turn_ref"] = "trace#2"
    if variation == "wrong-operation":
        operation["operation_id"] = "op-2"
    if variation == "unknown-state":
        operation["state"] = "Accepted"
    if variation == "failed-operation":
        operation["state"] = "Failed"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:
            pass

        def reply(self, value: Any, status: int = 200) -> None:
            payload = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Mcp-Session-Id", "fixture-session")
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self) -> None:
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            calls.append(request)
            if self.path == "/judge":
                identifier = next(iter(request["questions"]))
                response: dict[str, Any] = {
                    "answers": {identifier: {"type": "noul", "noul": 0.03}}
                }
                if variation != "judge-missing-model":
                    response["model"] = "actual-fixture-model"
                self.reply(response)
                return
            if request["method"] == "initialize":
                result: Any = {"protocolVersion": "2025-11-25", "capabilities": {}}
            else:
                result = {"structuredContent": operation, "content": []}
            self.reply({"jsonrpc": "2.0", "id": request["id"], "result": result})

        def do_GET(self) -> None:
            parsed = urllib.parse.urlsplit(self.path)
            calls.append(
                {"get": parsed.path, "query": urllib.parse.parse_qs(parsed.query)}
            )
            if parsed.path == "/health":
                base = (
                    str(workspace)
                    if variation != "wrong-workspace"
                    else str(workspace / "other")
                )
                self.reply(
                    {
                        "paths": {"effective_base_path": base},
                        "build": {"binary_commit": "fixture_only"},
                    }
                )
            elif parsed.path.endswith("/provider-input/part"):
                content = raw.decode()
                if variation == "corrupt-part":
                    content = content.replace("constraint", "CONSTRAINT")
                self.reply(
                    {
                        "schema": "masc.provider-input-part.v1",
                        "keeper": "fixture-keeper",
                        "turn_ref": "trace#1",
                        "part": part,
                        "text": content,
                    }
                )
            elif parsed.path.endswith("/provider-input"):
                self.reply(
                    {
                        "schema": "masc.provider-input-manifest.v1",
                        "keeper": "fixture-keeper",
                        "turn_ref": "trace#2"
                        if variation == "wrong-input-turn"
                        else "trace#1",
                        "wire": {
                            "capture_id": "capture-1",
                            "body_sha256": "prepared_only",
                        },
                        "parts": [part],
                    }
                )
            elif parsed.path.endswith("/turn-records"):
                self.reply(
                    {
                        "keeper": "fixture-keeper",
                        "turn_ref": "trace#1",
                        "entries": []
                        if variation == "missing-record"
                        else [
                            {
                                "record": {
                                    "keeper": "fixture-keeper",
                                    "turn_ref": "trace#1",
                                    "execution_ids": ["exec-1"],
                                    "response_observed_model_input": None,
                                }
                            }
                        ],
                    }
                )
            elif parsed.path.endswith("/turn-transcript"):
                self.reply(
                    {
                        "schema": "masc.keeper.turn-transcript.v2",
                        "keeper": "fixture-keeper",
                        "turn_ref": "trace#1",
                        "found": variation != "missing-transcript",
                    }
                )
            elif parsed.path.endswith("/tool-calls"):
                self.reply(
                    {
                        "keeper": "other-keeper"
                        if variation == "wrong-tool-owner"
                        else "fixture-keeper",
                        "execution_id": "exec-1",
                        "entry": {
                            "record_kind": "tool_call",
                            "tool": "keeper_context_status",
                        },
                    }
                )
            else:
                self.reply({"error": "unknown fixture route"}, 404)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/mcp", calls
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


class CaptureProtocol(unittest.TestCase):
    def capture(
        self, variation: str, preserve_into: pathlib.Path | None = None
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, Any], list[dict[str, Any]]]:
        with tempfile.TemporaryDirectory() as directory:
            workspace = pathlib.Path(directory)
            output = workspace / "evidence"
            with fixture(workspace, variation) as (endpoint, calls):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "capture",
                        "--mcp-url",
                        endpoint,
                        "--keeper",
                        "fixture-keeper",
                        "--expected-base-path",
                        str(workspace),
                        "--output",
                        str(output),
                        "--operation-id",
                        "op-1",
                        "--request-timeout",
                        "2",
                        "--wait-timeout",
                        "2",
                        "--poll-interval",
                        "0.01",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            report = json.loads((output / "report.json").read_bytes())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            for path in output.rglob("*"):
                if path.is_file():
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            for event in report["events"]:
                self.assertEqual(
                    hashlib.sha256((output / event["path"]).read_bytes()).hexdigest(),
                    event["sha256"],
                )
            if preserve_into is not None:
                shutil.copytree(output, preserve_into)
            return result, report, calls

    def test_real_protocol_shape_keeps_reply_input_and_action_separate(self) -> None:
        result, report, calls = self.capture("valid")
        self.assertEqual(result.returncode, 0, result.stderr)
        step = report["timeline"][0]
        self.assertEqual(
            step["reply"][0]["text"], "Continue the read-only investigation."
        )
        self.assertEqual(len(step["working_state_messages"]), 1)
        self.assertEqual(step["tool_calls"][0]["execution_id"], "exec-1")
        self.assertEqual(report["body_response_binding"], "not_established")
        self.assertEqual(report["librarian_causal_attribution"], "not_established")
        self.assertIsNone(report["continuity_pass"])
        self.assertEqual(
            [c["params"]["name"] for c in calls if c.get("method") == "tools/call"],
            ["masc_keeper_delegate_status"],
        )

    def test_natural_language_marker_is_not_working_state(self) -> None:
        result, report, _ = self.capture("prose-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["timeline"][0]["working_state_messages"], [])

    def test_invalid_or_missing_owner_evidence_never_becomes_captured(self) -> None:
        for variation in (
            "reply-unavailable",
            "wrong-reply-turn",
            "wrong-operation",
            "unknown-state",
            "failed-operation",
            "corrupt-part",
            "wrong-input-turn",
            "missing-record",
            "missing-transcript",
            "wrong-tool-owner",
        ):
            with self.subTest(variation=variation):
                result, report, calls = self.capture(variation)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(report["measurement_status"], "incomplete")
                self.assertNotEqual(report["timeline"][0]["status"], "captured")
                self.assertTrue(
                    all(
                        c["params"]["name"] == "masc_keeper_delegate_status"
                        for c in calls
                        if c.get("method") == "tools/call"
                    )
                )

    def test_wrong_workspace_stops_before_mcp(self) -> None:
        result, report, calls = self.capture("wrong-workspace")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["timeline"], [])
        self.assertFalse(any("method" in call for call in calls))

    def test_assessment_does_not_replay_keeper_operations_or_modify_its_source(
        self,
    ) -> None:
        scenario = {
            "schema": "masc.keeper-continuity-scenario.v1",
            "instructions": "Fixture only.",
            "steps": [
                {
                    "id": "op-1",
                    "kind": "message",
                    "prompt": "Earlier fixture observation.",
                    "criteria": [
                        {
                            "id": "retained",
                            "scope": "reply",
                            "proposition": "The reply continues the observation.",
                        }
                    ],
                }
            ],
        }
        for variation in (
            "valid",
            "missing-evidence",
            "altered-reply",
            "altered-event",
            "altered-working-state",
            "altered-binary",
            "altered-prompt",
            "reused-operation",
            "unobserved-restart",
        ):
            with (
                self.subTest(variation=variation),
                tempfile.TemporaryDirectory() as directory,
            ):
                workspace = pathlib.Path(directory)
                _, source, _ = self.capture("valid", workspace / "original")
                original = workspace / "original/report.json"
                # Explicit run-submission fixtures precede the captured status read.
                submissions = []
                for kind, payload in (
                    (
                        "tool_started",
                        {
                            "name": "masc_keeper_msg",
                            "arguments": {
                                "name": "fixture-keeper",
                                "message": scenario["steps"][0]["prompt"],
                            },
                        },
                    ),
                    (
                        "tool_response",
                        {
                            "name": "masc_keeper_msg",
                            "response": {
                                "result": {
                                    "structuredContent": {"operation_id": "op-1"}
                                }
                            },
                        },
                    ),
                ):
                    raw = json.dumps(payload).encode()
                    relative = f"raw/fixture-submission-{kind}.json"
                    (original.parent / relative).write_bytes(raw)
                    submissions.append(
                        {
                            "kind": kind,
                            "path": relative,
                            "sha256": hashlib.sha256(raw).hexdigest(),
                        }
                    )
                source["events"][1:1] = submissions
                source["scenario"] = copy.deepcopy(scenario)
                if variation == "missing-evidence":
                    source["timeline"][0] = {
                        "step_id": "op-1",
                        "status": "captured",
                        "reply": [{"text": "invented"}],
                    }
                elif variation == "altered-reply":
                    source["timeline"][0]["reply"][0]["text"] = "invented"
                elif variation == "altered-working-state":
                    source["timeline"][0]["working_state_messages"] = []
                elif variation == "altered-event":
                    (original.parent / source["events"][-1]["path"]).write_text("{}")
                elif variation == "altered-binary":
                    source["server_build"]["binary_commit"] = "invented"
                elif variation == "altered-prompt":
                    source["scenario"]["steps"][0]["prompt"] = "Never submitted."
                elif variation == "reused-operation":
                    step = copy.deepcopy(source["scenario"]["steps"][0])
                    step["id"] = "another-step"
                    source["scenario"]["steps"].append(step)
                    item = copy.deepcopy(source["timeline"][0])
                    item["step_id"] = "another-step"
                    source["timeline"].append(item)
                elif variation == "unobserved-restart":
                    source["scenario"]["steps"].append(
                        {"id": "restart", "kind": "restart"}
                    )
                    source["timeline"].append(
                        {"step_id": "restart", "status": "restart_observed"}
                    )
                source["scenario_sha256"] = hashlib.sha256(
                    json.dumps(
                        source["scenario"],
                        ensure_ascii=False,
                        allow_nan=False,
                        indent=2,
                    ).encode()
                ).hexdigest()
                original.write_text(json.dumps(source))
                original_bytes = original.read_bytes()
                config = workspace / "runtime.toml"
                config.write_text("[typesafeai]\nexcluded_keepers = []\n")
                output = workspace / "assessment"
                with fixture(workspace, "valid") as (endpoint, calls):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(SCRIPT),
                            "assess",
                            "--capture-report",
                            str(original),
                            "--keeper",
                            "fixture-keeper",
                            "--request-timeout",
                            "2",
                            "--runtime-config",
                            str(config),
                            "--judge-endpoint",
                            endpoint.removesuffix("/mcp") + "/judge",
                            "--judge-model",
                            "fixture-alias",
                            "--output",
                            str(output),
                        ],
                        capture_output=True,
                        text=True,
                        check=False,
                        env={**os.environ, "TYPESAFEAI_API_KEY": "fixture-only-key"},
                    )
                report = json.loads((output / "report.json").read_bytes())
                self.assertEqual(original.read_bytes(), original_bytes)
                self.assertFalse(
                    any("method" in call or "get" in call for call in calls)
                )
                if variation != "valid":
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertEqual(report["measurement_status"], "incomplete")
                    self.assertEqual(calls, [])
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    report["source_capture_sha256"],
                    hashlib.sha256(original_bytes).hexdigest(),
                )
                self.assertEqual(
                    report["provenance"], "assessment_of_captured_keeper_evidence"
                )
                self.assertIsNone(report["continuity_pass"])
                self.assertEqual(len(calls), 1)


class SemanticProtocol(unittest.TestCase):
    def measure(
        self, variation: str
    ) -> tuple[dict[str, Any], list[dict[str, Any]], Exception | None]:
        namespace = runpy.run_path(str(SCRIPT), run_name="harness_fixture")
        with tempfile.TemporaryDirectory() as directory:
            workspace = pathlib.Path(directory)
            policy = workspace / "runtime.toml"
            policy.write_text(
                '[typesafeai]\nexcluded_keepers = ["fixture-keeper"]\n'
                if variation == "excluded"
                else "[typesafeai]\nexcluded_keepers = []\n"
            )
            with fixture(workspace, variation) as (endpoint, calls):

                class Recorded:
                    def __init__(self) -> None:
                        from argparse import Namespace

                        self.args = Namespace(
                            runtime_config=str(policy),
                            keeper="fixture-keeper",
                            judge_model="requested-fixture-alias",
                            judge_endpoint=endpoint.removesuffix("/mcp") + "/judge",
                            request_timeout=2,
                        )
                        self.report: dict[str, Any] = {
                            "timeline": [
                                {"reply": [{"text": "first answer"}]},
                                {"reply": [{"text": "later answer"}]},
                            ]
                        }

                    def save(self) -> None:
                        pass

                capture = Recorded()
                scenario = {
                    "steps": [
                        {
                            "id": "earlier",
                            "kind": "message",
                            "prompt": "earlier observation",
                            "criteria": [
                                {
                                    "id": "first",
                                    "scope": "reply",
                                    "proposition": "Does the first answer preserve the earlier observation?",
                                }
                            ],
                        },
                        {
                            "id": "later",
                            "kind": "message",
                            "prompt": "future correction",
                            "criteria": [
                                {
                                    "id": "second",
                                    "scope": "reply",
                                    "proposition": "Does the later answer reflect the correction?",
                                }
                            ],
                        },
                    ]
                }
                failure = None
                with mock.patch.dict(
                    "os.environ", {"TYPESAFEAI_API_KEY": "fixture-only-key"}
                ):
                    try:
                        namespace["judge"](capture, scenario)
                    except namespace["AcceptanceError"] as error:
                        failure = error
            return capture.report, calls, failure

    def test_judge_gets_only_the_past_and_retains_raw_probability_and_actual_model(
        self,
    ) -> None:
        report, requests, failure = self.measure("valid")
        self.assertIsNone(failure)
        self.assertEqual(
            [row["id"] for row in requests[0]["state"]["reference_up_to_checkpoint"]],
            ["earlier"],
        )
        self.assertEqual(
            [row["id"] for row in requests[1]["state"]["reference_up_to_checkpoint"]],
            ["earlier", "later"],
        )
        measured = report["timeline"][0]["judgments"][0]
        self.assertEqual(measured["request"], requests[0])
        self.assertEqual(measured["probability"], 0.03)
        self.assertEqual(measured["response_model"], "actual-fixture-model")
        self.assertNotIn("passed", measured)
        self.assertEqual(report["semantic_verdict"], "raw_probabilities_only")

    def test_unattributed_judge_response_is_retained_but_not_measured(self) -> None:
        report, _, failure = self.measure("judge-missing-model")
        self.assertIsNotNone(failure)
        judgment = report["timeline"][0]["judgments"][0]
        self.assertIn("response", judgment)
        self.assertNotEqual(judgment["status"], "measured")

    def test_runtime_keeper_exclusion_is_respected_before_any_judge_call(self) -> None:
        _, requests, failure = self.measure("excluded")
        self.assertIsNotNone(failure)
        self.assertEqual(requests, [])


if __name__ == "__main__":
    unittest.main()
