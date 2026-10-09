"""The deletion list does not read a server whose workspace is unconfirmed.

A health read that fails after a match keeps the match unconfirmed. If the
same port is by then served by another workspace, a deletion list read sent
now would put that workspace's rows into the screen that still shows the
first one. The list on screen stays until a confirmed read replaces it.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import threading
from typing import Any, cast

import tui_keyboard_harness as h
from tui_keyboard_memory import memory_facts_http_fixtures

DELETIONS = "/api/v1/dashboard/keepers/deletions"
ROW_A = b"workspace-a-row"
ROW_B = b"workspace-b-row"


def inventory(marker: bytes) -> h.HttpResponse:
    return 200, {
        "operations": [],
        "errors": [],
        "configuration_removals": [],
        "configuration_errors": [marker.decode()],
    }


def run(executable: str) -> None:
    fixtures = memory_facts_http_fixtures()
    lock = threading.Lock()
    served = {"phase": "a", "reads": 0, "failed_health": 0, "good_health": 0}
    base = ""

    def prepare(path):
        nonlocal base
        h.seed_row_budget_workspace(path)
        base = str(Path(path).resolve())

    def health() -> h.RawHttpResponse | h.HttpResponse:
        with lock:
            phase = served["phase"]
        with lock:
            served["good_health" if phase == "a" else "failed_health"] += 1
        if phase == "unconfirmed":
            return h.RawHttpResponse(
                503, b'{"error":"identity unavailable"}', content_type="application/json"
            )
        _, raw_payload = h.fleet_safety_fixture()
        payload = cast(dict[str, Any], raw_payload)
        payload["paths"] = {
            "effective_base_path": base,
            "effective_masc_root": str(Path(base, ".masc")),
        }
        return h.RawHttpResponse(
            200, json.dumps(payload).encode(), content_type="application/json"
        )

    def deletions() -> h.HttpResponse:
        with lock:
            served["reads"] += 1
            phase = served["phase"]
        # While the health read is failing, another workspace answers.
        return inventory(ROW_B if phase == "unconfirmed" else ROW_A)

    def reads() -> int:
        with lock:
            return served["reads"]

    fixtures[DELETIONS] = deletions
    fixtures["/health"] = cast(h.HttpFixture, health)
    fixtures["/health?full=1"] = cast(h.HttpFixture, health)

    def interact(process, fd, _slave, output, _base):
        def screen() -> bytes:
            end = output.rfind(h.FRAME_END)
            return (
                h.screen_text(bytes(output[: end + len(h.FRAME_END)])) if end >= 0 else b""
            )

        def until(predicate, description):
            assert h.wait_for_fixture_state(process, fd, output, predicate, timeout=8), (
                description,
                screen(),
            )

        h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
        os.write(fd, b"D")
        until(lambda: ROW_A in screen(), "A deletion list not shown")
        confirmed_reads = reads()
        with lock:
            served["phase"] = "unconfirmed"
        # The first failed read marks the identity unconfirmed. The later ones
        # give the TUI time to apply it before the key is pressed.
        until(lambda: served["failed_health"] >= 4, "health failure not read")
        h.drain_until_quiet(process, fd, output)
        os.write(fd, b"r")
        h.drain_until_quiet(process, fd, output)
        assert reads() == confirmed_reads, ("a deletion read went out while unconfirmed", reads(), confirmed_reads, served, screen())
        assert ROW_A in screen() and ROW_B not in screen(), screen()
        with lock:
            served["phase"] = "a"
            good_before = served["good_health"]
        until(lambda: served["good_health"] >= good_before + 4, "health not read again")
        h.drain_until_quiet(process, fd, output)
        os.write(fd, b"r")
        until(lambda: reads() > confirmed_reads, "no deletion read after confirmation")
        assert ROW_A in screen() and ROW_B not in screen(), screen()
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Deletion list waits for a confirmed workspace",
        interact=interact,
        prepare_workspace=prepare,
        http_fixtures=fixtures,
        refresh=0.2,
        terminal_cols=140,
    )
    print("Keeper deletions identity: PASS", flush=True)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
