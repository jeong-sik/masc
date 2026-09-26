"""The chat /copy command sends the stored reply bytes, before display wrapping.

SOURCE_MODULES makes the PR edited-tests selector run this PTY scenario when
the command, history reader, or terminal writer changes.
"""
import base64
import hashlib
import re
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_command.ml",
    "bin/masc_tui_keeper_chat_history.ml",
    "bin/masc_tui_link.ml",
)

LONG_REPLY = (
    "The first line is longer than the chat viewport: "
    + "measure the original bytes, not the cells on screen. " * 4
    + "\n\n"
    + "one\ttwo\tthree\n"
    + "last line · 한글"
)
OSC52 = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)\x07")


def run(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (
        200,
        [
            {"id": "older-answer", "role": "assistant",
             "content": "older answer", "ts": 1787348491.0},
            {"id": "latest-answer", "role": "assistant",
             "content": LONG_REPLY, "ts": 1787348491.0},
            {"id": "latest-question", "role": "user",
             "content": "new question is not a reply", "ts": 1787348492.0},
            {"id": "older-autonomous", "role": "assistant",
             "content": "older autonomous reply", "ts": 1787348490.0,
             "autonomous_turn": {}},
        ],
    )

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.wait_for_output(process, fd, output, b"last line", start=0, timeout=10)
        frame = h.send_and_wait(process, fd, output, b"/copy\r", OSC52)
        match = OSC52.search(frame)
        assert match is not None, "the /copy command emitted no OSC 52"
        copied = base64.b64decode(match.group(1), validate=True)
        expected = LONG_REPLY.encode()
        assert copied == expected, (
            f"OSC 52 decoded bytes differ: want {hashlib.sha256(expected).hexdigest()}, "
            f"got {hashlib.sha256(copied).hexdigest()}"
        )
        assert copied.count(b"\n") == expected.count(b"\n") == 3
        assert b"\t" in copied and len(expected.splitlines()[0]) > 100
        count_notice = f"({len(LONG_REPLY)} characters, {len(expected)} bytes)".encode()
        h.wait_for_output(process, fd, output, count_notice, start=0, timeout=5)
        h.wait_for_output(process, fd, output, b"terminal support unconfirmed",
                          start=0, timeout=5)
        print("CHAT_COPY_PTY bytes=%d newlines=%d sha256=%s" %
              (len(copied), copied.count(b"\n"), hashlib.sha256(copied).hexdigest()),
              flush=True)
        # Keep A's second GET pending while B's later /copy completes. The
        # terminal clipboard must keep B even when A finally responds.
        old_reply = "alpha reply that must not replace beta"
        slow_alpha = h.GatedHttpResponse(
            (200, [{"id": "slow-alpha", "role": "assistant",
                    "content": old_reply, "ts": 1787348493.0}]),
            hold_seconds=30.0,
        )
        fixtures["/api/v1/keepers/alpha/chat/history"] = slow_alpha
        beta_reply = "beta reply requested last"
        fixtures["/api/v1/keepers/beta/chat/history"] = (
            200, [{"id": "beta-answer", "role": "assistant",
                   "content": beta_reply, "ts": 1787348494.0}],
        )
        try:
            os.write(fd, b"/copy\r")
            assert h.wait_for_fixture_state(
                process, fd, output, slow_alpha.requested.is_set, timeout=5.0
            ), "alpha /copy did not start"
            h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"beta")
            h.send_and_wait(
                process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta"
            )
            h.send_and_wait(
                process, fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat"
            )
            h.wait_for_output(process, fd, output, beta_reply.encode(),
                              start=0, timeout=10)
            frame = h.send_and_wait(process, fd, output, b"/copy\r", OSC52)
            match = OSC52.search(frame)
            assert match is not None
            assert base64.b64decode(match.group(1), validate=True) == beta_reply.encode()
            after_beta = len(output)
            assert not slow_alpha.completed.is_set(), "alpha GET settled before beta /copy"
            slow_alpha.release.set()
            assert h.wait_for_fixture_state(
                process, fd, output, slow_alpha.completed.is_set, timeout=5.0
            ), "alpha response did not leave the fixture"
            assert not h.poll_for_output(
                process, fd, output, OSC52, start=after_beta, timeout=1.0
            ), "late alpha /copy replaced beta on the terminal clipboard"
            print("CHAT_COPY_ORDER_PTY beta remains latest after alpha settles", flush=True)
        finally:
            slow_alpha.release.set()

        h.send_and_wait(process, fd, output, b"\x03",
                        b"Ctrl-C: press again to quit")

    h.run_terminal_scenario(
        binary,
        description="chat copy preserves original multiline reply bytes",
        interact=interact,
        confirm_exit=b"\x03",
        http_fixtures=fixtures,
    )
    print("chat copy pty: PASS", flush=True)


if __name__ == "__main__":
    run(sys.argv[1])
