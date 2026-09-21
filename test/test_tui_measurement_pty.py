"""A real TUI reads synthetic measurement artifacts through HTTP by SHA."""

from __future__ import annotations

import argparse
from collections.abc import Iterator
import copy
import hashlib
import json
import os
from pathlib import Path
import re
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
    "lib/tui_decode.ml",
    "lib/tui_decode.mli",
    "lib/masc_http_client/pool.ml",
    "lib/masc_http_client/pool.mli",
    "lib/masc_http_client/masc_http_client.ml",
    "lib/masc_http_client/masc_http_client.mli",
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
        "overlay-return": report(
            "overlay-origin", [sample("overlay-context", "Scored")]
        ),
        "overlay-palette": report(
            "overlay-origin", [sample("overlay-context", "Scored")]
        ),
        "theme-preview": report("theme-preview", [sample("retained", "Scored")]),
        "oversized-length": report("must-not-render", [sample("oversized", "Scored")]),
        "oversized-unfinished": report(
            "must-not-render", [sample("oversized", "Scored")]
        ),
        "oversized-lane": report("unused", []),
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
    elif scenario == "probabilities-preview":
        values[scenario] = report(
            "many-probabilities",
            [
                sample(f"case-{index:03d}-" + "x" * 1024, "Scored", provided=True)
                for index in range(96)
            ]
            + [sample("last-failure", "Judge_failed")],
        )
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
    body_started = threading.Event()
    release_body = threading.Event()
    if scenario in ("oversized-length", "oversized-unfinished", "oversized-lane"):
        oversized_bytes = 4 * 1024 * 1024 + 1

        def unfinished_body() -> Iterator[bytes]:
            body_started.set()
            if scenario == "oversized-unfinished":
                yield b"x" * oversized_bytes
            release_body.wait()

        # The existing streaming fixture sends headers before asking for body
        # chunks. Fixed-length refusal must need no body; a close-delimited
        # response must be refused without waiting for its end.
        fixtures["/api/v1/artifacts/" + sha] = h.StreamingHttpResponse(
            unfinished_body,
            headers=(("Content-Length", str(oversized_bytes)),)
            if scenario in ("oversized-length", "oversized-lane")
            else (),
        )
        if scenario == "oversized-lane":
            fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
            fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
            fixtures[h.lane_runs_path("librarian_exact")] = (
                200,
                {
                    "runs": [
                        {
                            "run_id": "oversized",
                            "run_kind": "exact_output",
                            "lane": "librarian_exact",
                            "actor": "fixture",
                            "started_at": 1787557000.0,
                            "status": "succeeded",
                            "elapsed_s": 1.0,
                            "selected_slot": "fixture",
                        }
                    ],
                    "has_more": False,
                    "total": 1,
                },
            )
            fixtures["/api/v1/dashboard/exact-lane-runs/oversized"] = fixtures[
                "/api/v1/artifacts/" + sha
            ]
    if scenario == "malformed":
        fixtures["/api/v1/artifacts/" + sha] = h.RawHttpResponse(
            200, b"{", content_type="application/json"
        )
    new_sha, new_response = artifact(
        report("new-result", [sample("new-sample", "Answer_ready")])
    )
    fixtures["/api/v1/artifacts/" + new_sha] = new_response
    status_requested = threading.Event()
    if scenario in ("overlay", "overlay-lanes", "overlay-return", "overlay-palette"):
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
        fixtures[h.REPOSITORIES_PATH] = h.repositories_fixture()
        fixtures["/api/v1/repositories/masc/changes"] = (
            200,
            {
                **status_response[1],
                "scope": {"kind": "repository", "repository_id": "masc"},
            },
        )

    def interact_body(process, master, _slave, output, _base):
        h.send_and_wait(process, master, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master, output, b"alpha")

        def check_receive_limit() -> None:
            reason = b"HTTP 200: body exceeds 4194304 bytes"
            h.wait_for_output(process, master, output, reason, start=0, timeout=3.0)
            screen = h.screen_text(bytes(output))
            assert body_started.is_set() and not release_body.is_set()
            # The ordinary 100-column frame must show the reason and limit;
            # the long artifact URL may follow beyond the visible line.
            assert reason in screen, screen
            if evidence is not None:
                evidence.mkdir(parents=True, exist_ok=True)
                (evidence / (scenario + ".pty")).write_bytes(output)
                (evidence / (scenario + ".txt")).write_bytes(screen)

        if scenario == "oversized-lane":
            h.palette_go(process, master, output, b"go lanes", b"Librarian")
            h.send_and_wait(
                process,
                master,
                output,
                b"/Librarian",
                re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian"),
            )
            h.send_and_wait(process, master, output, b"\x1b", b"j/k:move")
            h.send_and_wait(process, master, output, b"\r", b"1 loaded / 1 retained")
            h.send_and_wait(
                process, master, output, b"\r", b"Lane run detail: GET failed:"
            )
            check_receive_limit()
            os.write(master, b"q")
            return

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

        if scenario in ("overlay-lanes", "overlay-palette"):
            h.palette_go(process, master, output, b"go lanes", b"MASC Lanes")
        if scenario in (
            "overlay",
            "overlay-lanes",
            "overlay-return",
            "overlay-palette",
        ):
            # Lanes does not draw the repository overlay, but its Esc handler
            # still sees it. The HTTP fixture proves /diff opened that state.
            submit_command(
                "/diff",
                h.FRAME_START
                if scenario in ("overlay-lanes", "overlay-palette")
                else b"overlay-file.ml",
            )
            assert status_requested.wait(2.0), "repository changes were not requested"
        if scenario == "overlay-palette":
            # Returning to the same surface need not repaint its title.
            h.palette_go(process, master, output, b"go lanes", b"j/k:move")
            h.send_and_wait(process, master, output, b"\x1b", b"MASC Overview")
        if scenario == "theme-preview":
            h.palette_go(process, master, output, b"go Config / themes", b"MASC Themes")
            h.wait_for_output(
                process, master, output, b"terminal colours", start=0, timeout=3.0
            )
            preview = h.send_and_wait(
                process, master, output, b"j", b"Enter:pick another"
            )
            assert b"\x1b]4;" in preview and b"\x1b]11;" in preview, preview
        before_command = len(output)
        submit_command("/measurement " + sha, b"MASC Measurement")
        if scenario == "theme-preview":
            transition = bytes(output[before_command:])
            for reset in (b"\x1b]110\x1b\\", b"\x1b]111\x1b\\", b"\x1b]104\x1b\\"):
                assert reset in transition, (
                    "measurement kept an uncommitted theme",
                    reset,
                    transition,
                )
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
            "overlay-return": b"SCORED 1",
            "overlay-palette": b"SCORED 1",
            "theme-preview": b"SCORED 1",
            "probabilities-preview": b"SCORED 96",
            "oversized-length": b"Measurement: GET failed:",
            "oversized-unfinished": b"Measurement: GET failed:",
        }[scenario]
        h.wait_for_output(process, master, output, expected, start=0, timeout=5.0)
        if scenario in ("oversized-length", "oversized-unfinished"):
            check_receive_limit()
            h.send_and_wait(process, master, output, b"\x1b", b"MASC Lanes")
            os.write(master, b"q")
            return
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
        elif scenario in (
            "overlay",
            "overlay-lanes",
            "overlay-return",
            "overlay-palette",
        ):
            assert b"overlay-origin" in screen and b"SCORED 1" in screen, screen
            closed = h.send_and_wait(process, master, output, b"\x1b", b"MASC Lanes")
            assert b"MASC Measurement" not in h.screen_text(closed), closed
            if scenario == "overlay-return":
                h.palette_go(
                    process, master, output, b"go Workspace", b"MASC Workspace"
                )
                h.send_and_wait(process, master, output, b"d", b"overlay-file.ml")
                closed = h.send_and_wait(
                    process, master, output, b"\x1b", b"MASC Workspace"
                )
                assert "Keepers ▸ alpha ▸ chat".encode() not in h.screen_text(closed), (
                    closed
                )
                # A new /diff still owns its direct return to Keeper chat.
                submit_command("/diff", b"overlay-file.ml")
                h.send_and_wait(
                    process, master, output, b"\x1b", "Keepers ▸ alpha ▸ chat".encode()
                )
                h.escape_to_keeper_detail(process, master, output, name=b"alpha")
        elif scenario == "theme-preview":
            h.palette_go(
                process, master, output, b"go Config / themes", b"terminal colours"
            )
        elif scenario == "probabilities-preview":
            for needle in (
                b"SCORED 96",
                b"FAILED 1",
                b"INCOMPLETE 0",
                b"output truncated",
                b"full report:",
                b"measurement-result.json",
                b"BLOB SHA256",
            ):
                assert needle in screen, (needle, screen)
            # The overview covers the entire report; the explicitly labelled
            # text preview need not contain every probability or failure stage.
            h.send_and_wait(process, master, output, b"\x1b", b"MASC Lanes")
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

    def interact(process, master, slave, output, base):
        try:
            interact_body(process, master, slave, output, base)
        finally:
            release_body.set()
            if delayed is not None:
                delayed.release.set()

    h.run_terminal_scenario(
        executable,
        description="Noul measurement: " + scenario,
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


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
        "overlay-return",
        "overlay-palette",
        "theme-preview",
        "probabilities-preview",
        "oversized-length",
        "oversized-unfinished",
        "oversized-lane",
    ):
        run(os.path.abspath(args.executable), name, args.evidence_dir)
    print("TUI measurement and lane artifacts: 17 scenarios PASS")
