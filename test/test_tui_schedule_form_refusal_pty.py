"""A refused Schedules create form stays on the Schedules surface.

The footer's last-action line is cleared by the next key, and a workspace
warning can take its place before that. A refusal the operator has to act
on (here: the editor form is not a JSON object) is drawn in the Schedules
body for the last-action window instead, so it is still on screen after a
key that cleared the footer.
"""
import os
import sys
import tempfile
from pathlib import Path

import tui_keyboard_harness as h
import tui_keyboard_schedule as schedule

REFUSAL = b"create: the editor form must be a JSON object"


def body_rows(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return [rows[key] for key in sorted(rows)]


def run(executable):
    fixtures = schedule.schedule_detail_http_fixtures()
    created = []

    def create(body):
        created.append(body)
        return 200, {"result": {"content": [{"type": "text", "text": "created"}]}}

    fixtures["/api/v1/tools/masc_schedule_create"] = h.RequestHttpResponse(create)

    with tempfile.TemporaryDirectory() as directory:
        editor = Path(directory) / "array-form.sh"
        # A JSON array is JSON, so it reaches the object check rather than the
        # parse error.
        editor.write_text("#!/bin/sh\nprintf %s '[]' > \"$1\"\n")
        editor.chmod(0o755)

        def interact(process, fd, _slave, output, _base):
            h.palette_go(process, fd, output, b"go schedules", b"Requests: 1")
            h.drain_until_quiet(process, fd, output)
            start = len(output)
            os.write(fd, b"n")
            h.wait_for_output(process, fd, output, REFUSAL, start=start, timeout=10)
            h.drain_until_quiet(process, fd, output)
            # The next key clears the footer's last-action line; the body
            # keeps the refusal for the rest of its window.
            start = len(output)
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=5)
            h.drain_until_quiet(process, fd, output)
            rows = body_rows(output)
            assert any(REFUSAL in row for row in rows), rows
            assert not created, "a refused form reached the create route"
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description="a refused Schedules create form stays on the surface",
            interact=interact,
            http_fixtures=fixtures,
            extra_env={"EDITOR": str(editor), "VISUAL": str(editor)},
        )
    print("tui schedule form refusal: PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_schedule_form_refusal_pty.py <masc_tui.exe>")
    run(os.path.abspath(sys.argv[1]))
