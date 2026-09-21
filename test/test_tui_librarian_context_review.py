"""Project durable Context-review evidence through the real TUI detail view."""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, cast
import zlib

import test_tui_keyboard_input as h

TUI_SCENARIOS = {
    "faithful",
    "needs-revision",
    "http-failure",
    "cancel-review",
}


def run_case(executable: str, fixture: dict[str, Any]) -> None:
    run = fixture["detail"]["run"]
    result = run["output"]
    review = result["context_review"]
    write = result["context_write"]
    run_id = run["run_id"]
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    fixtures[h.lane_runs_path("librarian_exact")] = (200, fixture["page"])
    reads: list[str] = []

    def detail() -> h.HttpResponse:
        reads.append(run_id)
        return 200, fixture["detail"]

    fixtures["/api/v1/dashboard/exact-lane-runs/" + run_id] = detail

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
        h.send_and_wait(process, fd, output, b"\r", b"context_review")
        h.drain_until_quiet(process, fd, output)
        needles = [
            b'"context_review"',
            b'"context_write"',
            f'"status": "{review["status"]}"'.encode(),
            f'"status": "{write["status"]}"'.encode(),
            b"RUN  " + run["status"].encode(),
        ]
        if "verdict" in review:
            needles.append(f'"verdict": "{review["verdict"]}"'.encode())
        if "response" in review:
            needles.append(review["response"]["model"].encode())
            needles.append(b'"request_body_sha256"')
        seen = h.screen_text(bytes(output))
        for _ in range(len(json.dumps(result, indent=2).splitlines()) + 1):
            if all(needle in seen for needle in needles):
                break
            h.read_available(fd, output)
            start = len(output)
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=3)
            h.drain_until_quiet(process, fd, output)
            seen += b"\n" + h.screen_text(bytes(output))
        for needle in needles:
            if needle not in seen:
                raise AssertionError(f"{fixture['scenario']}: missing {needle!r}")
        if reads != [run_id]:
            raise AssertionError(f"unexpected detail reads: {reads}")
        print(
            "CONTEXT_REVIEW_PTY_EVIDENCE "
            + json.dumps(
                {
                    "scenario": fixture["scenario"],
                    "run_id": run_id,
                    "run_status": run["status"],
                    "review_status": review["status"],
                    "context_write": write,
                    "detail_reads": reads,
                    "binary_sha256": hashlib.sha256(
                        Path(executable).read_bytes()
                    ).hexdigest(),
                    "encoding": "zlib+base64",
                    "pty": base64.b64encode(zlib.compress(bytes(output))).decode(),
                }
            ),
            flush=True,
        )
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Context review: " + fixture["scenario"],
        interact=interact,
        http_fixtures=fixtures,
    )


def main() -> None:
    executable = h.tui_executable(sys.argv[1])
    producer = str(Path(sys.argv[2]).resolve())
    test_dir = Path(__file__).resolve().parent
    env = os.environ.copy()
    env["DUNE_SOURCEROOT"] = str(test_dir.parent)
    result = subprocess.run(
        [producer, "-v"],
        cwd=test_dir,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=120,
    )
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    prefix = "CONTEXT_REVIEW_FIXTURE "
    all_fixtures = [
        cast(dict[str, Any], json.loads(line[len(prefix) :]))
        for line in result.stdout.splitlines()
        if line.startswith(prefix)
    ]
    fixtures = [
        fixture for fixture in all_fixtures if fixture["scenario"] in TUI_SCENARIOS
    ]
    scenarios = {cast(str, fixture["scenario"]) for fixture in fixtures}
    if scenarios != TUI_SCENARIOS:
        raise AssertionError(
            f"producer emitted TUI scenarios {sorted(scenarios)}, "
            f"expected {sorted(TUI_SCENARIOS)}"
        )
    for fixture in fixtures:
        run_case(executable, fixture)
    print("Context review durable evidence reaches the TUI: PASS")


if __name__ == "__main__":
    main()
