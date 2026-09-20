"""A real TUI reads synthetic measurement artifacts through HTTP by SHA."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import threading
from typing import Any

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "lib/librarian_continuity_report.ml",
)


def generation(text: str) -> dict[str, Any]:
    return {
        "request": {
            "runtime_id": "fixture-runtime",
            "requested_model": "requested-model",
            "prompt": {"system": "Synthetic fixture", "user": "Synthetic input"},
            "prepared_requests": [],
        },
        "response": {
            "response_id": "fixture-response",
            "model": "actual-answer-model",
            "text": text,
        },
    }


def sample(
    identity: str, stage: str, probability: float = 0.875, *, provided: bool = False
) -> dict[str, Any]:
    question_text = "What is the cabinet code?"
    question = (
        ["Provided", question_text]
        if provided
        else ["Generated", generation(question_text)]
    )
    answer = generation(
        "ORCHID-731" if identity == "retained" else "Information unavailable."
    )
    request = {
        "endpoint": "https://judge.invalid/eval",
        "model": "requested-judge",
        "question_id": identity,
        "reference": "The cabinet code is ORCHID-731.",
        "question": question_text,
        "answer": answer["response"]["text"],
        "instructions": "Does this answer recover the reference?",
        "true_criteria": "The requested information is accurately recovered.",
        "false_criteria": "The information is missing or incorrect.",
    }
    if stage == "Scored":
        progress = [
            stage,
            {
                "question": question,
                "answer": answer,
                "judgment": {
                    "request": request,
                    "response_model": "actual-judge-model",
                    "request_body_sha256": "b" * 64,
                    "probability": probability,
                },
            },
        ]
    elif stage == "Judge_failed":
        progress = [
            stage,
            {
                "question": question,
                "answer": answer,
                "failure": {
                    "request": request,
                    "error": "synthetic provider HTTP 503",
                },
            },
        ]
    elif stage == "Question_ready":
        progress = [stage, question]
    elif stage == "Answer_ready":
        progress = [stage, {"question": question, "answer": answer}]
    else:
        raise ValueError(stage)
    return {
        "case": {
            "id": identity,
            "question": question_text if provided else None,
            "source": {
                "trace_id": "synthetic-source",
                "turn": 1,
                "text": request["reference"],
            },
            "context": {
                "keeper_name": "synthetic-keeper",
                "trace_id": "synthetic-later",
                "read_position": 17,
                "facts": [{"id": "cabinet", "claim": request["reference"]}]
                if identity == "retained"
                else [],
                "unread": "The cabinet is still locked.",
            },
        },
        "progress": progress,
    }


def report(identity: str, samples: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "schema": "masc.librarian-continuity.v1",
        "provenance": ["Synthetic"],
        "run_id": identity,
        "started_at": "2026-09-21T00:00:00Z",
        "input_path": "synthetic.json",
        "input_sha256": "a" * 64,
        "output_path": "measurement-result.json",
        "config_revision": "fixture-config",
        "binary_commit": None,
        "executable_sha256": None,
        "samples": samples,
    }


def artifact(value: dict[str, Any]) -> tuple[str, h.HttpResponse]:
    content = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    sha = hashlib.sha256(content.encode()).hexdigest()
    return sha, (
        200,
        {
            "sha256": sha,
            "bytes": len(content.encode()),
            "mime": "text/plain",
            "content": content,
        },
    )


def run(executable: str, scenario: str, evidence: Path | None) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    requests: h.HttpRequests = []
    values = {
        "contexts": report(
            "two-contexts",
            [
                sample("retained", "Scored", provided=True),
                sample("absent", "Scored", 0.125, provided=True),
            ],
        ),
        "incomplete": report(
            "incomplete-stages",
            [sample("question", "Question_ready"), sample("answer", "Answer_ready")],
        ),
        "failed": report("provider-failure", [sample("failed", "Judge_failed")]),
        "integrity": report("must-not-render", [sample("tampered", "Scored")]),
        "missing": report("must-not-render", [sample("missing", "Scored")]),
        "stale": report("old-result", [sample("old-sample", "Scored")]),
        "overlay": report("overlay-origin", [sample("overlay-context", "Scored")]),
        "overlay-lanes": report(
            "overlay-origin", [sample("overlay-context", "Scored")]
        ),
    }
    if scenario == "large":
        large = sample("large", "Scored", provided=True)
        answer_text = "synthetic answer " * 80_000
        large["progress"][1]["answer"]["response"]["text"] = answer_text
        large["progress"][1]["judgment"]["request"]["answer"] = answer_text
        values[scenario] = report(
            "large-valid-report",
            [large, sample("after-large", "Scored", 0.125, provided=True)],
        )
    elif scenario == "malformed":
        values[scenario] = report("must-not-render", [sample("malformed", "Scored")])
    sha, response = artifact(values[scenario])
    if scenario == "integrity":
        response = copy.deepcopy(response)
        assert isinstance(response[1], dict)
        response[1]["content"] = "x" + response[1]["content"][1:]
    if scenario == "missing":
        response = (404, {"error": "artifact not found"})
    delayed = (
        h.GatedHttpResponse(response, hold_seconds=15.0)
        if scenario == "stale"
        else None
    )
    fixtures["/api/v1/artifacts/" + sha] = response if delayed is None else delayed
    if scenario == "malformed":
        fixtures["/api/v1/artifacts/" + sha] = h.RawHttpResponse(
            200, b"{", content_type="application/json"
        )
    new_sha, new_response = artifact(
        report("new-result", [sample("new-sample", "Answer_ready")])
    )
    fixtures["/api/v1/artifacts/" + new_sha] = new_response
    status_requested = threading.Event()
    if scenario in ("overlay", "overlay-lanes"):
        status_response: h.HttpResponse = (
            200,
            {
                "scope": {"kind": "project"},
                "changes": [
                    {
                        "path": "overlay-file.ml",
                        "staged": False,
                        "unstaged": True,
                        "untracked": False,
                        "conflicted": False,
                    }
                ],
                "total": 1,
            },
        )

        def read_status() -> h.HttpResponse:
            status_requested.set()
            return status_response

        fixtures["/api/v1/git/status"] = read_status

    def interact(process, master, _slave, output, _base):
        h.send_and_wait(process, master, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master, output, b"alpha")

        def submit_command(text: str, needle: bytes) -> None:
            h.send_and_wait(process, master, output, b"i", b"Ctrl-Y to speak")
            command = text.encode()
            h.send_and_wait(
                process,
                master,
                output,
                h.PASTE_START + command + h.PASTE_END,
                command,
            )
            h.send_and_wait(process, master, output, b"\r", needle)

        if scenario == "overlay-lanes":
            h.palette_go(process, master, output, b"go lanes", b"MASC Lanes")
        if scenario in ("overlay", "overlay-lanes"):
            submit_command(
                "/diff",
                h.FRAME_START if scenario == "overlay-lanes" else b"overlay-file.ml",
            )
            assert status_requested.wait(2.0), "repository changes were not requested"
        submit_command("/measurement " + sha, b"MASC Measurement")
        expected = {
            "contexts": b"SCORED 2",
            "incomplete": b"INCOMPLETE 2",
            "failed": b"FAILED 1",
            "integrity": b"content hashes to",
            "missing": b"artifact not found",
            "stale": b"loading measurement",
            "large": b"SCORED 2",
            "malformed": b"not JSON",
            "overlay": b"SCORED 1",
            "overlay-lanes": b"SCORED 1",
        }[scenario]
        h.wait_for_output(process, master, output, expected, start=0, timeout=5.0)
        if delayed is not None:
            assert delayed.requested.wait(2.0), "old artifact was not requested"
            submit_command("/measurement " + new_sha, b"new-result")
            delayed.release.set()
            assert delayed.completed.wait(2.0), "old artifact was not released"
        before = len(output)
        h.resize_and_wait(
            process,
            master,
            output,
            rows=70 if scenario == "large" else 50,
            columns=90 if scenario == "large" else 200,
            needle=b"MASC Measurement",
            controls=(h.FULL_REDRAW,),
        )
        redraw = output.find(h.FULL_REDRAW, before)
        assert redraw >= 0
        h.wait_for_output(
            process, master, output, h.FRAME_END, start=redraw, timeout=3.0
        )
        end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
        start = output.rfind(h.FRAME_START, before, redraw)
        assert start >= 0
        screen = h.screen_text(bytes(output[start:end]))
        if scenario == "large":
            assert b"SCORED 2" in screen and b"INCOMPLETE 0" in screen, screen
            for needle in (
                b"output truncated",
                b"full report:",
                b"measurement-result.json",
                b"after-large",
                b"0.125",
                b"0.875",
                b"SCORED 2",
            ):
                assert needle in screen, (needle, screen)
            # A bounded display remains interactive after the large response.
            h.send_and_wait(process, master, output, b"\x1b", b"MASC Lanes")
        elif scenario == "contexts":
            for needle in (
                b"SCORED 2",
                b"FAILED 0",
                b"INCOMPLETE 0",
                b"0.125",
                b"0.875",
                b"actual-answer-model",
                b"actual-judge-model",
                b"CONTEXT SHA256",
                b"AUTHORITATIVE FILE",
                b"measurement-result.json",
                b"BLOB SHA256",
                b"QUESTION PROVIDED",
            ):
                assert needle in screen, (needle, screen)
            assert b"APPROVED" not in screen and b"librarian_exact" not in screen, (
                screen
            )
        elif scenario == "incomplete":
            for needle in (
                b"INCOMPLETE 2",
                b"SCORED 0",
                b"FAILED 0",
                b"QUESTION READY",
                b"ANSWER READY",
            ):
                assert needle in screen, (needle, screen)
            assert b"No scored samples" in screen, screen
        elif scenario == "failed":
            for needle in (
                b"FAILED 1",
                b"SCORED 0",
                b"JUDGE FAILED",
                b"synthetic provider HTTP 503",
            ):
                assert needle in screen, (needle, screen)
        elif scenario == "malformed":
            assert b"not JSON" in screen and b"must-not-render" not in screen, screen
        elif scenario == "integrity":
            assert (
                b"content hashes to" in screen and b"must-not-render" not in screen
            ), screen
        elif scenario == "missing":
            assert (
                b"artifact not found" in screen and b"must-not-render" not in screen
            ), screen
        elif scenario == "stale":
            assert b"new-result" in screen and b"old-result" not in screen, screen
            assert b"INCOMPLETE 1" in screen and b"SCORED 0" in screen, screen
        elif scenario in ("overlay", "overlay-lanes"):
            assert b"overlay-origin" in screen and b"SCORED 1" in screen, screen
            closed = h.send_and_wait(process, master, output, b"\x1b", b"MASC Lanes")
            assert b"MASC Measurement" not in h.screen_text(closed), closed
        if evidence is not None:
            evidence.mkdir(parents=True, exist_ok=True)
            (evidence / (scenario + ".pty")).write_bytes(output)
            (evidence / (scenario + ".txt")).write_bytes(screen)
        # The shared HTTP harness records POSTs only; GETs are served without
        # appending to this list. A decoded fixture establishes the read.
        assert not any(path.startswith("/api/v1/artifacts/") for path, _ in requests), (
            "artifact inspection posted a request"
        )
        os.write(master, b"q")

    try:
        h.run_terminal_scenario(
            executable,
            description="Noul measurement: " + scenario,
            interact=interact,
            http_fixtures=fixtures,
            http_requests=requests,
        )
    finally:
        if delayed is not None:
            delayed.release.set()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    for name in (
        "contexts",
        "incomplete",
        "failed",
        "integrity",
        "missing",
        "stale",
        "large",
        "malformed",
        "overlay",
        "overlay-lanes",
    ):
        run(os.path.abspath(args.executable), name, args.evidence_dir)
    print("TUI Noul measurement: 10 scenarios PASS")
