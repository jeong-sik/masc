"""A real TUI reads synthetic measurement artifacts through HTTP by SHA."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
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


def sample(identity: str, stage: str, probability: float = 0.875) -> dict[str, Any]:
    question = generation("What is the cabinet code?")
    answer = generation(
        "ORCHID-731" if identity == "retained" else "Information unavailable."
    )
    request = {
        "endpoint": "https://judge.invalid/eval",
        "model": "requested-judge",
        "question_id": identity,
        "reference": "The cabinet code is ORCHID-731.",
        "question": question["response"]["text"],
        "answer": answer["response"]["text"],
        "instructions": "Does this answer recover the reference?",
        "true_criteria": "The requested information is accurately recovered.",
        "false_criteria": "The information is missing or incorrect.",
    }
    if stage == "Scored":
        progress = [
            stage,
            question,
            answer,
            {
                "request": request,
                "response_model": "actual-judge-model",
                "request_body_sha256": "b" * 64,
                "probability": probability,
            },
        ]
    elif stage == "Judge_failed":
        progress = [
            stage,
            question,
            answer,
            {"request": request, "error": "synthetic provider HTTP 503"},
        ]
    elif stage == "Question_ready":
        progress = [stage, question]
    elif stage == "Answer_ready":
        progress = [stage, question, answer]
    else:
        raise ValueError(stage)
    return {
        "case": {
            "id": identity,
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
        "schema": "masc.librarian-continuity.synthetic.v1",
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
            [sample("retained", "Scored"), sample("absent", "Scored", 0.125)],
        ),
        "incomplete": report(
            "incomplete-stages",
            [sample("question", "Question_ready"), sample("answer", "Answer_ready")],
        ),
        "failed": report("provider-failure", [sample("failed", "Judge_failed")]),
        "integrity": report("must-not-render", [sample("tampered", "Scored")]),
        "missing": report("must-not-render", [sample("missing", "Scored")]),
        "stale": report("old-result", [sample("old-sample", "Scored")]),
    }
    sha, response = artifact(values[scenario])
    if scenario == "integrity":
        response = copy.deepcopy(response)
        assert isinstance(response[1], dict)
        response[1]["content"] += " "
    if scenario == "missing":
        response = (404, {"error": "artifact not found"})
    delayed = (
        h.GatedHttpResponse(response, hold_seconds=15.0)
        if scenario == "stale"
        else None
    )
    fixtures["/api/v1/artifacts/" + sha] = response if delayed is None else delayed
    new_sha, new_response = artifact(
        report("new-result", [sample("new-sample", "Answer_ready")])
    )
    fixtures["/api/v1/artifacts/" + new_sha] = new_response

    def interact(process, master, _slave, output, _base):
        h.send_and_wait(process, master, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master, output, b"alpha")

        def open_artifact(selected: str, needle: bytes) -> None:
            h.send_and_wait(process, master, output, b"i", b"Ctrl-Y to speak")
            command = ("/measurement " + selected).encode()
            h.send_and_wait(
                process,
                master,
                output,
                h.PASTE_START + command + h.PASTE_END,
                command,
            )
            h.send_and_wait(process, master, output, b"\r", needle)

        open_artifact(sha, b"MASC Measurement")
        expected = {
            "contexts": b"SCORED 2",
            "incomplete": b"INCOMPLETE 2",
            "failed": b"FAILED 1",
            "integrity": b"does not match",
            "missing": b"artifact not found",
            "stale": b"loading measurement",
        }[scenario]
        h.wait_for_output(process, master, output, expected, start=0, timeout=5.0)
        if delayed is not None:
            assert delayed.requested.wait(2.0), "old artifact was not requested"
            open_artifact(new_sha, b"new-result")
            delayed.release.set()
            assert delayed.completed.wait(2.0), "old artifact was not released"
        before = len(output)
        h.resize_and_wait(
            process,
            master,
            output,
            rows=50,
            columns=200,
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
        if scenario == "contexts":
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
        elif scenario == "integrity":
            assert b"does not match" in screen and b"must-not-render" not in screen, (
                screen
            )
        elif scenario == "missing":
            assert (
                b"artifact not found" in screen and b"must-not-render" not in screen
            ), screen
        elif scenario == "stale":
            assert b"new-result" in screen and b"old-result" not in screen, screen
            assert b"INCOMPLETE 1" in screen and b"SCORED 0" in screen, screen
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
    for name in ("contexts", "incomplete", "failed", "integrity", "missing", "stale"):
        run(os.path.abspath(args.executable), name, args.evidence_dir)
    print("TUI Noul measurement: 6 scenarios PASS")
