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


def _row_success(row: dict[str, Any]) -> bool:
    """Mirror ``Tui_decode.decode_keeper_call``'s success fallback (#37461,
    #37650 review).

    The durable tool-call record stopped always carrying a boolean
    ``success``: a real row (as ``test_keeper_task_skill_turn_exact``
    prints below) carries only ``wire_outcome`` and sometimes
    ``disposition``, never ``success``. Read ``success`` first for any
    row that does send it explicitly; otherwise fall back to
    ``disposition`` then ``wire_outcome``, oldest-first, exactly as the
    OCaml decoder does. ``wire_outcome == "unknown"`` is not a success
    signal there either: the decoder refuses the row outright (a wire
    that does not know the outcome is not evidence the call completed),
    so this raises the same way rather than guessing ``True``.
    """
    if "success" in row:
        return cast(bool, row["success"])
    disposition = row.get("disposition")
    if disposition in ("completed", "deferred"):
        return True
    if disposition == "failed":
        return False
    wire_outcome = row.get("wire_outcome")
    if wire_outcome == "ok":
        return True
    if wire_outcome == "error":
        return False
    if wire_outcome == "unknown":
        raise ValueError("row wire_outcome is unknown; the TUI decoder refuses it")
    raise KeyError("row has no success, disposition, or wire_outcome field")


def _rendered_output(screen: bytes, call_index: int) -> bytes:
    """The ``output`` field's value as the exact call view wrapped it.

    ``render_keeper_calls`` draws each wrapped chunk of a field on its own
    row, repeating the ``#N output `` label on every chunk so a two-row
    viewport never separates a continuation from its field. A value the wrap
    cut mid-token therefore reads as two rows with the label between them,
    and ``screen_text`` (rows joined by a newline) never contains the token:
    the failed row's ``withheld_activation_failure`` straddles a chunk
    boundary at 180 columns, so a search over the joined rows timed out on a
    screen that was already showing it. Strip the repeated label and the row
    padding, then join the chunks with nothing between them, so a token the
    wrap cut in half reads whole again.
    """
    label = b"#%d output " % (call_index + 1)
    chunks: list[bytes] = []
    for line in screen.split(b"\n"):
        stripped = line.lstrip()
        if stripped.startswith(label):
            chunks.append(stripped[len(label) :].rstrip())
    return b"".join(chunks)


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
            if _row_success(row)
            else [
                b"skill_activation_error",
                b"skill_applicability",
                b"fixture-jev",
                b"withheld_activation_failure",
            ]
        )
        seen = _rendered_output(screen, 0)
        # The exact call view wraps persisted output; walk rows instead of
        # assuming the answer is contained in its old 72-byte timeline digest.
        for _ in range(len(str(row["output"])) + 1):
            if all(needle in seen for needle in needles):
                break
            h.read_available(fd, output)
            start = len(output)
            os.write(fd, b"j")
            # A j at the last row changes nothing, and Frame_presenter.present
            # writes nothing at all for an unchanged frame -- not even a frame
            # terminator -- so waiting for FRAME_END here would time out on a
            # screen that already shows everything. Stop at the bottom.
            if not h.poll_for_output(
                process, fd, output, h.FRAME_END, start=start, timeout=3
            ):
                break
            h.drain_until_quiet(process, fd, output)
            seen += b"\n" + _rendered_output(h.screen_text(bytes(output)), 0)
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
                    "success": _row_success(row),
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

    def prepare_workspace(base_path: str) -> None:
        directory = Path(base_path, ".masc", "keepers")
        for default_name in ("alpha", "beta"):
            directory.joinpath(default_name + ".json").unlink()
        directory.joinpath(keeper + ".json").write_text(
            json.dumps(h.keeper_metadata(keeper)), encoding="utf-8"
        )

    h.run_terminal_scenario(
        executable,
        description="Skill applicability durable call",
        interact=interact,
        http_fixtures=fixtures,
        prepare_workspace=prepare_workspace,
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
    if len(rows) != 7:
        raise AssertionError(f"expected seven real handler records, got {len(rows)}")
    for row in rows:
        run_case(executable, row)
    print("Skill applicability durable calls reach the TUI: PASS")


if __name__ == "__main__":
    main()
