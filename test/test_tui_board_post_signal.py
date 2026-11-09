#!/usr/bin/env python3
"""The open Board post reads again when the server announces a Board write
that names it or names no post, and again after a failed read (RFC-0480 L4).

The refresh cadence is pushed out of the test's lifetime, so every post read
after the post opens comes from an announcement or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


POST_ID = "post-7"
POST_PATH = "/api/v1/board/" + POST_ID


def post() -> dict[str, object]:
    return {
        "id": POST_ID,
        "author": "ann",
        "title": "Fixture post",
        "body": "Fixture body",
        "votes": 0,
        "comment_count": 0,
        "created_at": 1.0,
    }


def post_detail() -> dict[str, object]:
    return {
        "post": post(),
        "comment_context": [],
        "comments": [],
        "comment_revision": "0" * 64,
        "comment_page": {"offset": 0, "total": 0},
    }


class BoardHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(BoardServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/api/v1/board":
            server.record(request.path)
            self.respond(200, {"posts": [post()]}, workspace_receipt=True)
        elif request.path == "/api/v1/board/hearths":
            server.record(request.path)
            self.respond(200, {"hearths": []}, workspace_receipt=True)
        elif request.path == POST_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.post_times.append(time.monotonic())
                fail = server.post_failures_left > 0
                if fail:
                    server.post_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "post unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(200, post_detail(), workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class BoardServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = BoardHandler
        self.post_times: list[float] = []
        self.post_failures_left = 0


def board_notification(params: dict[str, object]) -> dict[str, object]:
    return {"jsonrpc": "2.0", "method": "notifications/board", "params": params}


def post_changed(post_id: str) -> dict[str, object]:
    return board_notification(
        {"type": "post_changed", "event_type": "post.changed", "post_id": post_id, "change": "pinned"}
    )


def comment_voted() -> dict[str, object]:
    return board_notification(
        {"type": "comment_voted", "comment_id": "comment-3", "voter": "ann", "direction": "up"}
    )


class BoardPostSignalTest(unittest.TestCase):
    binary = ""

    def run_post(self, scenario: Callable[[BoardServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = BoardServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            board = cast(BoardServer, server)
            board.set_phase("open")
            # Keepers -> Board via the palette (#50465 took Board off the tab ring),
            # then open the first post.
            step("keys", ":go Work / Board")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: board.count("open", "/api/v1/board") >= 1,
                "the Board did not read its list",
            )
            step("drain", 1.0)
            step("keys", "\r")
            step(
                "wait",
                lambda: board.response_count("open", POST_PATH) >= 1,
                "the open post was not read",
            )
            step("drain", 1.0)
            scenario(board, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_board_write_about_the_open_post_is_read(self) -> None:
        def scenario(server: BoardServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(post_changed("post-other"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other post's change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", POST_PATH), 0)
            server.set_phase("changed")
            server.events.put(post_changed(POST_ID))
            step(
                "wait",
                lambda: server.response_count("changed", POST_PATH) == 1,
                "the open post's change did not cause a post read",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", POST_PATH), 1)
            # A vote on a comment names no post; it may be one of this post's.
            server.set_phase("unnamed")
            server.events.put(comment_voted())
            step(
                "wait",
                lambda: server.response_count("unnamed", POST_PATH) == 1,
                "a Board write naming no post did not cause a post read",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("unnamed", POST_PATH), 1)

        self.run_post(scenario)

    def test_failed_post_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: BoardServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.post_failures_left = 2
                server.post_times.clear()
            server.events.put(post_changed(POST_ID))
            step(
                "wait",
                lambda: len(server.post_times) >= 3,
                "two failed post reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.post_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_post(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_board_post_signal.py /path/to/masc_tui.exe")
    BoardPostSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
