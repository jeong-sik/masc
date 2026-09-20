"""Read real Librarian/JEV fixture runs after durable registry replay in the TUI."""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, cast
import zlib

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "lib/keeper/keeper_librarian_absorb_gate.ml",
    "lib/keeper/keeper_librarian_absorb_gate.mli",
    "lib/keeper/keeper_librarian_runtime.ml",
    "lib/typesafeai/typesafeai_config.ml",
    "lib/typesafeai/typesafeai_config.mli",
    "lib/typesafeai/typesafeai_types.ml",
    "lib/typesafeai/typesafeai_types.mli",
)


def run_case(executable: str, fixture_path: Path) -> None:
    encoded = fixture_path.read_bytes()
    fixture = cast(dict[str, Any], json.loads(encoded))
    scenario = cast(str, fixture["scenario"])
    detail = cast(dict[str, Any], fixture["detail"])
    run = cast(dict[str, Any], detail["run"])
    run_id = cast(str, run["run_id"])
    gate = cast(dict[str, Any], run["output"]["absorb_gate"])
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    fixtures[h.lane_runs_path("librarian_exact")] = (200, fixture["page"])
    detail_reads: list[str] = []

    def read_detail() -> h.HttpResponse:
        detail_reads.append(run_id)
        return 200, detail

    fixtures["/api/v1/dashboard/exact-lane-runs/" + run_id] = read_detail

    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        _base: str,
    ) -> None:
        h.resize_and_wait(
            process, fd, output, rows=42, columns=180, needle=b"MASC Overview"
        )
        h.palette_go(process, fd, output, b"go lanes", b"Librarian")
        h.send_and_wait(
            process,
            fd,
            output,
            b"/Librarian",
            re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian"),
        )
        h.send_and_wait(process, fd, output, b"\x1b", b"j/k:move")
        h.send_and_wait(process, fd, output, b"\r", b"1 loaded / 1 retained")
        h.send_and_wait(process, fd, output, b"\r", b"absorb_gate")
        h.drain_until_quiet(process, fd, output)
        first_screen = h.screen_text(bytes(output))
        status = b"failed" if scenario == "memory-write-failure" else b"succeeded"
        for needle in (b"absorb_gate", gate["status"].encode(), b"RUN  " + status):
            if needle not in first_screen:
                raise AssertionError(f"{scenario} first frame omitted {needle!r}")
        if gate["status"] != "skipped":
            boundary = f'"conveyed_boundary": {gate["conveyed_boundary"]}'.encode()
            if boundary not in first_screen:
                raise AssertionError(f"{scenario} first frame omitted {boundary!r}")
        if detail_reads != [run_id]:
            raise AssertionError(f"wrong detail reads: {detail_reads!r}")

        if gate["status"] == "skipped":
            needles = [cast(str, gate["reason"]).encode()]
        elif scenario == "http-failure":
            needles = [
                b"HTTP 503",
                b"fixture unavailable",
                b"configured-request-fixture",
            ]
        elif scenario == "invalid-answer":
            needles = [
                b"invalid_answer",
                b"returned_answers",
                b'"type": "choice"',
                b'"yes": 0.7',
                b'"noul": 0.0',
                b"configured-request-fixture",
            ]
        else:
            needles = [
                b"jev-fixture",
                b"configured-request-fixture",
                b'"s0_0": 1.0',
                b'"s1_0": 0.0',
            ]
            if scenario == "memory-write-failure":
                needles.append(cast(str, run["detail"]).encode())
        if gate["status"] != "skipped":
            needles.append(
                cast(str, gate["evaluations"][0]["request"]["endpoint"]).encode()
            )
        seen = first_screen
        # Only the short report is searched. The unrelated exact_output can
        # be much larger, so its size must not decide how far this test walks.
        for _ in range(len(json.dumps(gate, indent=2).splitlines()) + 1):
            if all(needle in seen for needle in needles):
                break
            h.read_available(fd, output)
            start = len(output)
            # Visit each row: the compare pane's PageDown step can exceed its
            # visible body, skipping request metadata between page windows.
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=3)
            h.drain_until_quiet(process, fd, output)
            seen += b"\n" + h.screen_text(bytes(output))
        for needle in needles:
            if needle not in seen:
                raise AssertionError(f"{scenario} did not render {needle!r}")

        if scenario == "judged":
            if len(json.dumps(run["output"]["exact_output"])) <= 65536:
                raise AssertionError("the real model output did not exceed the preview")
            if b"EXACT_OUTPUT_TAIL" in first_screen:
                raise AssertionError("the fixture did not exercise the bounded preview")
            h.send_and_wait(process, fd, output, b"\x1b[F", b"truncated, total")
            h.send_and_wait(process, fd, output, b"\x1b[H", b"absorb_gate")

        print(
            "LIBRARIAN_ABSORB_GATE_PTY_EVIDENCE "
            + json.dumps(
                {
                    "scenario": scenario,
                    "run_id": run_id,
                    "run_status": run["status"],
                    "gate_status": gate["status"],
                    "source_fixture_sha256": hashlib.sha256(encoded).hexdigest(),
                    "binary_sha256": hashlib.sha256(
                        Path(executable).read_bytes()
                    ).hexdigest(),
                    "detail_reads": detail_reads,
                    "rows": 42,
                    "columns": 180,
                    "encoding": "zlib+base64",
                    "pty": base64.b64encode(zlib.compress(bytes(output))).decode(),
                }
            ),
            flush=True,
        )
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Librarian absorb gate: " + scenario,
        interact=interact,
        http_fixtures=fixtures,
    )


def main() -> None:
    executable = h.tui_executable(sys.argv[1])
    producer = str(Path(sys.argv[2]).resolve())
    test_dir = Path(__file__).resolve().parent
    environment = os.environ.copy()
    environment["DUNE_SOURCEROOT"] = str(test_dir.parent)
    with tempfile.TemporaryDirectory(
        prefix="librarian-gate-run-fixtures-"
    ) as directory:
        subprocess.run(
            [producer, "--emit-tui-fixtures", directory],
            cwd=test_dir,
            env=environment,
            check=True,
            timeout=120,
        )
        for scenario in (
            "judged",
            "disabled",
            "lane-disabled",
            "missing-key",
            "http-failure",
            "invalid-answer",
            "memory-write-failure",
        ):
            run_case(executable, Path(directory, scenario + ".json"))
    print("Librarian absorb gate durable evidence reaches the TUI: PASS")


if __name__ == "__main__":
    main()
