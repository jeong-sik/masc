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


PANE_BORDER = "\u2502".encode()
OUTPUT_PANE_ROWS = re.compile(rb"RUN RESULT\s+\d+-\d+/(\d+)")


def unwrapped(screen: bytes) -> bytes:
    """The run result pane's rows joined end to end, without a separator.

    The pane draws the report as a JSON code block and cuts a line wider than
    itself where it runs out of cells, so a value deep in the report continues
    on the next row. Joining the rows puts such a value back together,
    whatever the pane's width. No needle spans two JSON lines, so joining
    cannot make one match.
    """
    return b"".join(
        row.rpartition(PANE_BORDER)[2].strip() for row in screen.split(b"\n")
    )


def output_pane_rows(screen: bytes) -> int:
    """How many rows the run result pane holds, read from its title.

    The title's window reads ``first-last/total`` over the rows the pane
    actually draws. The report's JSON line count undercounts them: a line
    wider than the pane takes two rows or more, and one ``j`` visits one row.
    """
    match = OUTPUT_PANE_ROWS.search(screen)
    if match is None:
        raise AssertionError(f"run result pane omitted its row window: {screen!r}")
    return int(match.group(1))


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
        status = cast(str, run["status"]).encode()
        for needle in (b"absorb_gate", gate["status"].encode(), b"RUN  " + status):
            if needle not in first_screen:
                raise AssertionError(f"{scenario} first frame omitted {needle!r}")
        if gate["status"] not in ("skipped", "incomplete"):
            boundary = f'"conveyed_boundary": {gate["conveyed_boundary"]}'.encode()
            if boundary not in first_screen:
                raise AssertionError(f"{scenario} first frame omitted {boundary!r}")
        if detail_reads != [run_id]:
            raise AssertionError(f"wrong detail reads: {detail_reads!r}")

        if gate["status"] == "skipped":
            needles = [cast(str, gate["reason"]).encode()]
        elif scenario in (
            "cancel-second-judgment",
            "cancel-after-commit",
            "cancel-after-completion",
        ):
            needles = [
                b"completed-jev",
                b"requested-cancel-model",
                b'"s0_0": 0.875',
            ]
        elif scenario == "http-failure":
            needles = [
                b"HTTP 503",
                b"fixture unavailable",
                b"configured-request-fixture",
            ]
        elif scenario in (
            "invalid-json",
            "invalid-response",
            "nonfinite-response",
            "duplicate-response",
            "nonutf8-response",
        ):
            response_marker = {
                "invalid-json": b"not JSON",
                "invalid-response": b"malformed-fixture",
                "nonfinite-response": b"NaN",
                "duplicate-response": b"duplicate-fixture",
                "nonutf8-response": b"base64",
            }[scenario]
            needles = [
                b'"kind": "http_response"',
                b'"status": 200',
                b'"body":',
                response_marker,
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
        if scenario in ("cancel-after-commit", "cancel-after-completion"):
            needles.extend(
                [
                    b'"after"',
                    f'"revision": {run["output"]["after"]["revision"]}'.encode(),
                ]
            )
        if gate["status"] != "skipped":
            needles.append(
                cast(
                    str,
                    gate["evaluations"][0]["request"]["destinations"][0]["destination_uri"],
                ).encode()
            )
        seen = first_screen
        joined = unwrapped(first_screen)

        def rendered(needle: bytes) -> bool:
            return needle in seen or needle in joined

        # One step visits one row, and the pane's title says how many rows
        # there are. The gate report is at the top of the output, ahead of
        # the exact_output, so the walk ends as soon as every needle has been
        # seen; only a failure walks the pane to its last row.
        for _ in range(output_pane_rows(first_screen)):
            if all(rendered(needle) for needle in needles):
                break
            h.read_available(fd, output)
            start = len(output)
            # Visit each row: the compare pane's PageDown step can exceed its
            # visible body, skipping request metadata between page windows.
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=3)
            h.drain_until_quiet(process, fd, output)
            screen = h.screen_text(bytes(output))
            seen += b"\n" + screen
            joined += b"\n" + unwrapped(screen)
        for needle in needles:
            if not rendered(needle):
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
    cancellation_producer = str(Path(sys.argv[3]).resolve())
    producer_timeout = 120
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
            timeout=producer_timeout,
        )
        for scenario in (
            "judged",
            "disabled",
            "lane-disabled",
            "missing-key",
            "excluded",
            "http-failure",
            "invalid-json",
            "invalid-response",
            "nonfinite-response",
            "duplicate-response",
            "nonutf8-response",
            "invalid-answer",
            "memory-write-failure",
        ):
            run_case(executable, Path(directory, scenario + ".json"))
        cancelled = subprocess.run(
            [cancellation_producer, "-v"],
            cwd=test_dir,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=producer_timeout,
        )
        print(cancelled.stdout, end="", flush=True)
        cancelled.check_returncode()
        partial: list[str] = []
        prefix = "CANCELLATION_FIXTURE "
        for line in cancelled.stdout.splitlines():
            if line.startswith(prefix):
                encoded = line[len(prefix) :]
                fixture = cast(dict[str, Any], json.loads(encoded))
                if fixture["scenario"] in (
                    "cancel-second-judgment",
                    "cancel-after-commit",
                    "cancel-after-completion",
                ):
                    partial.append(encoded)
        scenarios = [json.loads(encoded)["scenario"] for encoded in partial]
        if sorted(scenarios) != [
            "cancel-after-commit",
            "cancel-after-completion",
            "cancel-second-judgment",
        ]:
            raise AssertionError(f"unexpected cancellation fixtures: {scenarios}")
        for encoded in partial:
            fixture_path = Path(directory, json.loads(encoded)["scenario"] + ".json")
            fixture_path.write_text(encoded, encoding="utf-8")
            run_case(executable, fixture_path)
    print("Librarian absorb gate durable evidence reaches the TUI: PASS")


if __name__ == "__main__":
    main()
