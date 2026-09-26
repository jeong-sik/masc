"""The chat /copy command sends the stored reply bytes, before display wrapping.

SOURCE_MODULES makes the PR edited-tests selector run this PTY scenario when
the command, history reader, or terminal writer changes.
"""
import base64
import hashlib
import os
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
        ],
    )

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.wait_for_output(process, fd, output, b"one\\x09two", start=0, timeout=10)
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
        h.send_and_wait(process, fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary,
        description="chat copy preserves original multiline reply bytes",
        interact=interact,
        http_fixtures=fixtures,
    )
    print("chat copy pty: PASS", flush=True)


if __name__ == "__main__":
    run(sys.argv[1])
