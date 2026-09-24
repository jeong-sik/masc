"""A paused bracketed paste stays one chat draft until its closing marker."""
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_paste.ml",
    "bin/masc_tui_paste.mli",
)


def run(executable: str) -> None:
    requests: h.HttpRequests = []

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        h.send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")

        os.write(master_fd, h.PASTE_START + b"first line")
        # The old reader treated an idle half-second as the end marker. The
        # next pasted CR then became Return and submitted a fragment.
        time.sleep(0.8)
        h.send_and_wait(
            process, master_fd, output,
            b"\rsecond line" + h.PASTE_END,
            b"second line",
        )
        if any(path.endswith("/chat/stream") for path, _ in requests):
            raise AssertionError(f"paste sent before Enter: {requests!r}")

        os.write(master_fd, b"\r")
        body = h.wait_for_http_request(
            process, master_fd, output, requests,
            path="/api/v1/keepers/chat/stream",
        )
        message = json.loads(body).get("message")
        if message != "first line\nsecond line":
            raise AssertionError(f"paste was split or changed: {message!r}")
        h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A paused bracketed paste stays one draft",
        interact=interact,
        http_fixtures={
            "/api/v1/keepers/chat/stream":
                (503, {"error": "stop after the paste request capture"}),
        },
        http_requests=requests,
    )

    def editor_interact(process, master_fd, _slave_fd, output, _base_path):
        h.wait_for_output(process, master_fd, output, h.BRACKETED_PASTE_ON,
                          start=0, timeout=5.0)
        h.palette_go(process, master_fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, master_fd, output, b"w", b"MASC Board")
        start = len(output)
        h.send_and_wait(process, master_fd, output, b"\x05",
                        b"Board draft updated from editor")
        if h.BRACKETED_PASTE_ON not in output[start:]:
            raise AssertionError("bracketed paste was not reenabled after $EDITOR")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        h.send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-tui-paste-editor-") as directory:
        editor = Path(directory, "editor.sh")
        editor.write_text(
            "#!/bin/sh\n"
            "printf '%s' 'draft from editor' > \"$1\"\n"
            "printf '\\033[?2004l'\n"
        )
        editor.chmod(0o755)
        h.run_terminal_scenario(
            executable,
            description="Bracketed paste is reenabled after an editor returns",
            interact=editor_interact,
            extra_env={"EDITOR": str(editor)},
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("paused bracketed paste: PASS")
