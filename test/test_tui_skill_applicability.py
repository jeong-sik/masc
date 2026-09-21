"""Display real Skill handler outputs persisted by the tool-call log."""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, cast
import zlib

import test_tui_keyboard_input as h


def run_case(executable: str, row: dict[str, Any]) -> None:
    keeper = cast(str, row["keeper"])
    fixtures = h.keeper_runtime_http_fixtures()
    roster_key = "/api/v1/gate/keepers?detailed=true"
    original = fixtures[roster_key]
    assert isinstance(original, tuple)
    roster = cast(dict[str, Any], original[1])
    keeper_row = roster["keepers"][0]
    keeper_row["name"] = keeper
    keeper_row["meta"] = h.keeper_roster_meta(keeper)
    roster.update(keepers=[keeper_row], count=1, total=1)
    path = f"/api/v1/keepers/{keeper}/tool-calls?limit=100"
    reads: list[str] = []

    def calls() -> h.HttpResponse:
        reads.append(path)
        return 200, {"keeper": keeper, "count": 1, "health": "ok", "entries": [row]}

    fixtures[path] = calls

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
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, keeper.encode())
        h.send_and_wait(process, fd, output, b"t", b"calls (1)")
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        needles = (
            [b"JEV applicability advice"]
            if row["success"]
            else [
                b"skill_activation_error",
                b"skill_applicability",
                b"fixture-jev",
                b"withheld_activation_failure",
            ]
        )
        seen = screen
        # The exact call view wraps persisted output; walk rows instead of
        # assuming the answer is contained in its old 72-byte timeline digest.
        for _ in range(len(str(row["output"])) + 1):
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
                raise AssertionError(f"Skill call output did not render {needle!r}")
        if reads != [path]:
            raise AssertionError(f"unexpected log reads: {reads}")
        print(
            "SKILL_APPLICABILITY_PTY_EVIDENCE "
            + json.dumps(
                {
                    "keeper": keeper,
                    "success": row["success"],
                    "tool_use_id": row.get("tool_use_id"),
                    "row_sha256": hashlib.sha256(
                        json.dumps(row, sort_keys=True).encode()
                    ).hexdigest(),
                    "binary_sha256": hashlib.sha256(
                        Path(executable).read_bytes()
                    ).hexdigest(),
                    "detail_reads": reads,
                    "encoding": "zlib+base64",
                    "pty": base64.b64encode(zlib.compress(bytes(output))).decode(),
                }
            ),
            flush=True,
        )
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Skill applicability durable call",
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
        timeout=120,
        check=False,
    )
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    prefix = "SKILL_APPLICABILITY_TOOL_CALL "
    rows = [
        cast(dict[str, Any], json.loads(line[len(prefix) :]))
        for line in result.stdout.splitlines()
        if line.startswith(prefix)
    ]
    if len(rows) != 6:
        raise AssertionError(f"expected six real handler records, got {len(rows)}")
    for row in rows:
        run_case(executable, row)
    print("Skill applicability durable calls reach the TUI: PASS")


if __name__ == "__main__":
    main()
