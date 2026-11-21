#!/usr/bin/env python3
"""Preserve a TUI E2E failure frame instead of the last 3,000 bytes.

The tests used to report only ``terminal tail=output[-3000:]``.  That cut off
the line above the failing row, so a reviewer could not tell which cell held a
Keeper's name (#54253 follow-up, task-3866).  ``preserve`` writes the whole
frame — the two-cell table, its context and the state the run was in — to a
file under ``$RUNNER_TEMP/tui-e2e-frames/`` so the workflow can upload it as an
artifact.

Nothing here changes an assertion: it only runs from a failure path and
returns a path and a size for the failure message.
"""

from __future__ import annotations

import datetime
import os
import pathlib
import re

# The largest terminal transcript kept verbatim.  A 200x35 TUI redraws in
# bursts; 25 s of a failing test stays far below this, and a pathological
# stream is cut at a recorded boundary instead of silently.
MAX_FRAME_BYTES = 4 * 1024 * 1024


def frame_dir() -> pathlib.Path:
    """Where frames go: the runner's temp dir when CI gives one."""
    base = os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp"
    path = pathlib.Path(base) / "tui-e2e-frames"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _readable(raw: bytes) -> str:
    """A screen-shaped rendering: cursor moves become line breaks."""
    text = re.sub(rb"\x1b\[[0-9;]*H", b"\n", raw)
    text = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", text)
    return text.decode("utf-8", "backslashreplace")


def preserve(
    test_id: str,
    output: bytes,
    *,
    cols: int | None = None,
    rows: int | None = None,
    extra: dict[str, object] | None = None,
) -> tuple[str, int, bool]:
    """Write the failing frame and return ``(path, preserved_bytes, truncated)``."""
    raw = bytes(output)
    total = len(raw)
    truncated = total > MAX_FRAME_BYTES
    kept = raw[-MAX_FRAME_BYTES:] if truncated else raw
    path = frame_dir() / f"{re.sub(r'[^A-Za-z0-9_.-]', '_', test_id)}.frame.txt"
    header = [
        f"test: {test_id}",
        f"captured_utc: {datetime.datetime.now(datetime.timezone.utc).isoformat()}",
        f"cols: {cols}",
        f"rows: {rows}",
        f"output_bytes_total: {total}",
        f"output_bytes_kept: {len(kept)}",
        f"truncated_at_cap: {truncated}",
    ]
    for key, value in (extra or {}).items():
        header.append(f"{key}: {value}")
    body = [
        "",
        "--- readable (cursor moves become newlines; other escapes removed) ---",
        _readable(kept),
        "",
        "--- raw bytes (python repr) ---",
        repr(kept),
        "",
    ]
    path.write_text("\n".join(header) + "\n".join(body), encoding="utf-8")
    return str(path), len(kept), truncated
