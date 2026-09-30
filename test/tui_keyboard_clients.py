from __future__ import annotations

import os
import re
import subprocess

from tui_keyboard_harness import (
    CSI_RE,
    FULL_REDRAW,
    HttpFixtures,
    overview_event_http_fixtures,
    palette_go,
    resize_and_wait,
    send_and_wait,
)


def clients_row(
    name: str, agent_type: str, status: str, keeper: str | None, task: str | None
) -> dict[str, object]:
    return {
        "name": name,
        "agent_type": agent_type,
        "keeper_name": keeper,
        "status": status,
        "current_task": task,
        "session_bound_at": "2026-09-13T01:00:00Z",
        "last_seen": "2026-09-13T01:20:00Z",
        "capabilities": ["chat"],
    }


def clients_http_fixtures(*, extra_clients: int = 0) -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/clients"] = (
        200,
        {
            "schema": "masc.dashboard.clients.v1",
            "generated_at": "2026-09-13T01:21:00Z",
            "observation_only": True,
            "clients": [
                clients_row("codex-mcp-client", "codex", "active", None, None),
                clients_row("analyst-agent", "keeper", "busy", "analyst", "task-845"),
            ] + [
                clients_row(f"client-{index:02d}", "codex", "active", None, None)
                for index in range(extra_clients)
            ],
        },
    )
    return fixtures


def clients_footer_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Clients draws the footer row its listing frame counts.

    The key table declares j/k, p, Esc, / and n for Clients, and an armed
    search shows its query at the front of that row. Clients drew neither: the
    row stayed blank, and a typed search had nowhere on screen to appear."""
    # Landing on a row first: a search arms over rows, not over a roster that
    # has not loaded. Each step below changes the footer row itself, so the
    # presenter has to draw it again -- an unchanged row can be skipped.
    landed = palette_go(process, master_fd, output, b"go Clients", b"analyst-agent")
    # Column names are drawn the way every other list on the screen draws
    # them. Clients and the Activity feed spelled theirs "Status"/"Time"
    # while Memory, Board, Planning, Lanes and the logs used capitals.
    landed_plain = CSI_RE.sub(b"", landed)
    if b"STATUS" not in landed_plain or b"LAST SEEN" not in landed_plain:
        raise AssertionError(
            f"Clients did not name its columns in capitals: {landed_plain!r}"
        )
    # A query being typed ends in the caret search_marker draws, and carries
    # the count of rows it reaches when the surface can count them.
    send_and_wait(process, master_fd, output, b"/", b"/\xe2\x96\x8c  j/k:move")
    typed_query = re.compile(rb"/analyst(?: \((?:\d+|none)\))?\xe2\x96\x8c  ")
    send_and_wait(process, master_fd, output, b"analyst", typed_query)
    # Resizing keeps the armed query on screen even when the roster scrolls.
    for rows, columns in ((16, 80), (30, 100)):
        frame = resize_and_wait(
            process, master_fd, output, rows=rows, columns=columns,
            needle=typed_query, controls=(FULL_REDRAW,),
        )
        if b"j/k:move" not in CSI_RE.sub(b"", frame):
            raise AssertionError(f"Clients resize lost its key hints: {frame!r}")
    # Esc drops the query and stays on Clients; the row goes back to the keys.
    send_and_wait(process, master_fd, output, b"\x1b", b"j/k:move")
    os.write(master_fd, b"q")
