#!/usr/bin/env python3
"""The Memory screen sends the act a Keeper's writer row takes and draws the
server's answer (RFC librarian-call-only-proposes §12.4).

Each test serves one Keeper whose writer row takes the act under test. `w`
arms it and sends nothing, a second `w` posts it, and the answer the fixture
gives is drawn on the action line in the server's words.
"""

import json
import os
import pathlib
import re
import sys
import tempfile
import time
import unittest
import urllib.parse
from typing import Callable, TypeAlias, cast

import test_tui_chat_owed_history as owed
import tui_memory_health_rows as rows


HEALTH_PATH = "/api/v1/dashboard/keeper-memory-health"
KEEPER = "fixture-keeper"
ACT_PATH = "/api/v1/keepers/" + KEEPER + "/memory/act"
TURN_LOG = "log-1"
SNAPSHOT_SHA = "ab" * 32
# A colour change can sit inside a drawn line; the words between the changes
# are what the operator reads.
SGR = re.compile(rb"\x1b\[[0-9;:]*m")
# Any other control sequence moves the cursor or erases; the text between two
# of them is one written run.
CURSOR = re.compile(rb"\x1b\[[0-9;:?]*[A-Za-z]")
ROWS_SHOWN = 6

# The fixture's server class, kept before [run_act] points the fixture at the
# class of one test.
BaseChatServer: TypeAlias = owed.ChatServer

Json = dict[str, object]


def kept(last_read: object = None) -> Json:
    return {"lane": True, "last_read": last_read, "last_room": None, "read_alone": False}


def stopped_writer(stop: str, snapshot_file: Json) -> Json:
    return {
        "kind": "writer",
        "row": {
            "state": "stopped",
            "level": "error",
            "alarms": ["E1"],
            "request": {"kind": "view_unavailable"},
            "unread": None,
            "asking": None,
            **kept(),
            "stop": stop,
            "snapshot_file": snapshot_file,
        },
    }


def idle_writer(fault: Json) -> Json:
    """An idle writer whose last read ended on [fault] in [TURN_LOG]."""
    return {
        "kind": "writer",
        "row": {
            "state": "idle",
            "level": "ok",
            "alarms": [],
            "request": {"kind": "unknown_until_next_request"},
            "unread": True,
            "asking": None,
            **kept({"ended": "input_fault", "fault": fault}),
            "last_line": "started",
            "last_line_at": 1_700_000_000.0,
            "turn_log": TURN_LOG,
            "covers_through": "before_first",
            "memory": {"snapshot": "sha-memory", "facts": 3},
        },
    }


class ActServer(BaseChatServer):
    writer: Json = {"kind": "no_writer"}
    answer: tuple[int, Json] = (500, {})

    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ActHandler
        self.acts: list[object] = []

    def keeper_row(self) -> Json:
        return rows.keeper_row(KEEPER, writer=self.writer)


class ActHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(ActServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path != HEALTH_PATH:
            super().do_GET()
            return
        phase = server.record(HEALTH_PATH)
        if "keeper" in urllib.parse.parse_qs(request.query):
            body: Json = {
                "schema": rows.SCHEMA,
                "generated_at": 2.0,
                "keeper": server.keeper_row(),
            }
        else:
            body = rows.fleet([server.keeper_row()], execution={}, totals={})
        if self.respond(200, body, workspace_receipt=True):
            server.responded(phase, HEALTH_PATH)

    def do_POST(self) -> None:
        server = cast(ActServer, self.server)
        if urllib.parse.urlsplit(self.path).path != ACT_PATH:
            super().do_POST()
            return
        sent = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        phase = server.record(ACT_PATH)
        with server.condition:
            server.acts.append(sent)
        status, answer = server.answer
        if self.respond(status, answer):
            server.responded(phase, ACT_PATH)


def drawn_since(transcript: pathlib.Path, start: int) -> bytes:
    with transcript.open("rb") as handle:
        handle.seek(start)
        return SGR.sub(b"", handle.read())


def last_rows(drawn: bytes) -> list[bytes]:
    """The last rows written, one per cursor move, for a failure to show what
    the screen said instead."""
    written = [row.strip() for row in CURSOR.split(drawn)]
    return [row for row in written if row][-ROWS_SHOWN:]


class MemoryActTest(unittest.TestCase):
    binary = ""

    def run_act(
        self,
        writer: Json,
        arming: str,
        request: Json,
        answer: tuple[int, Json],
        drawn: bytes,
    ) -> None:
        """Serve [writer], press [arming] and then [w], and check the server
        got [request] once and the screen drew [drawn] after it."""
        served = type("Served", (ActServer,), {"writer": writer, "answer": answer})
        owed.ChatServer = served
        owed.ChatOwedHistoryTest.binary = self.binary

        with tempfile.TemporaryDirectory(prefix="masc-memory-act-") as scratch:
            transcript = pathlib.Path(scratch, "transcript")
            os.environ["MASC_TUI_TEST_TRANSCRIPT"] = str(transcript)

            def opened(server: BaseChatServer, step: Callable[..., None]) -> None:
                acting = cast(ActServer, server)
                acting.set_phase("open")
                step("keys", ":")
                step("drain", 0.3)
                step("keys", "go Memory")
                step("drain", 0.3)
                step("keys", "\r")
                step(
                    "wait",
                    lambda: acting.response_count("open", HEALTH_PATH) >= 1,
                    "the Memory surface did not read the memory health",
                )
                step("drain", 1.0)
                acting.set_phase("arming")
                for key in arming:
                    step("keys", key)
                    step("drain", 0.5)
                self.assertEqual(acting.count("arming", ACT_PATH), 0, "arming sent the act")
                acting.set_phase("sent")
                start = transcript.stat().st_size
                step("keys", "w")
                step(
                    "wait",
                    lambda: acting.response_count("sent", ACT_PATH) == 1,
                    "the second w did not send the act",
                )
                with acting.condition:
                    self.assertEqual(acting.acts, [request])
                deadline = time.monotonic() + owed.WAIT_SECONDS
                while drawn not in drawn_since(transcript, start) and time.monotonic() < deadline:
                    step("drain", 0.1)
                seen = drawn_since(transcript, start)
                self.assertIn(
                    drawn, seen, f"the answer {drawn!r} was not drawn; last rows: {last_rows(seen)!r}"
                )

            try:
                owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)
            finally:
                del os.environ["MASC_TUI_TEST_TRANSCRIPT"]

    def test_a_stopped_writer_resumes(self) -> None:
        self.run_act(
            stopped_writer("store_stopped_store_unwritable", {"fault": "absent"}),
            "w",
            {"action": "resume"},
            (200, {"ok": True, "keeper": KEEPER, "action": "resume", "store": "booting"}),
            b"store=booting",
        )

    def test_a_diverged_log_adopts_the_snapshot_file_it_shows(self) -> None:
        # The row takes resume first; W steps the arm to the adoption.
        self.run_act(
            stopped_writer(
                "store_stopped_log_diverged", {"sha": SNAPSHOT_SHA, "bytes": 120}
            ),
            "wW",
            {"action": "adopt", "observed": SNAPSHOT_SHA},
            (409, {"ok": False, "keeper": KEEPER, "action": "adopt", "code": "snapshot_mismatch"}),
            b"code=snapshot_mismatch",
        )

    def test_a_replaced_turn_log_restarts_on_the_id_the_disk_has(self) -> None:
        self.run_act(
            idle_writer({"kind": "turn_log_replaced", "expected": TURN_LOG, "observed": "log-2"}),
            "w",
            {"action": "restart_reading", "observed": "log-2"},
            (200, {"ok": True, "keeper": KEEPER, "action": "restart_reading", "store": "open"}),
            b"store=open",
        )

    def test_a_unit_that_does_not_read_is_skipped(self) -> None:
        self.run_act(
            idle_writer({"kind": "content_unreadable", "line": 7}),
            "w",
            {
                "action": "skip_item",
                "target": {"kind": "unreadable_unit", "turn_log": TURN_LOG, "line": 7},
            },
            (
                409,
                {
                    "ok": False,
                    "keeper": KEEPER,
                    "action": "skip_item",
                    "code": "not_the_head",
                    "now": {"kind": "unreadable_unit", "turn_log": TURN_LOG, "line": 9},
                },
            ),
            # The footer keeps the start of a notice longer than its room: beside
            # the fixture's build notice the line is cut inside the target, so the
            # code it leads with is what this checks. A body whose target did not
            # read would draw as an unanswered act, without the code.
            b"code=not_the_head",
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_memory_act.py /path/to/masc_tui.exe")
    MemoryActTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
