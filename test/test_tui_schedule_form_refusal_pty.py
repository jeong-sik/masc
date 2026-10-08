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
import threading
from pathlib import Path

import tui_keyboard_harness as h
import tui_keyboard_schedule as schedule

REFUSAL = b"create: the editor form must be a JSON object"
MODIFY_REFUSAL = b"modify: the store refuses to modify a running"
GUARD_REFUSAL = b"create: Workspace identity changed or is unavailable"
CREATE_PATH = "/api/v1/tools/masc_schedule_create"


def body_rows(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return [rows[key] for key in sorted(rows)]


def object_form_refusal(executable):
    fixtures = schedule.schedule_detail_http_fixtures()
    created = []

    def create(body):
        created.append(body)
        return 200, {"result": {"content": [{"type": "text", "text": "created"}]}}

    fixtures[CREATE_PATH] = h.RequestHttpResponse(create)

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


def modify_refused_before_the_editor_retires_the_create_refusal(executable):
    """The fixture's one schedule is running, which the store refuses to
    modify. That refusal is reported before any editor opens, and it must still
    retire the create refusal that was on the surface."""
    fixtures = schedule.schedule_detail_http_fixtures()
    with tempfile.TemporaryDirectory() as directory:
        editor = Path(directory) / "array-form.sh"
        editor.write_text("#!/bin/sh\nprintf %s '[]' > \"$1\"\n")
        editor.chmod(0o755)

        def interact(process, fd, _slave, output, _base):
            h.palette_go(process, fd, output, b"go schedules", b"Requests: 1")
            h.drain_until_quiet(process, fd, output)
            start = len(output)
            os.write(fd, b"n")
            h.wait_for_output(process, fd, output, REFUSAL, start=start, timeout=10)
            h.drain_until_quiet(process, fd, output)
            start = len(output)
            os.write(fd, b"e")
            h.wait_for_output(process, fd, output, MODIFY_REFUSAL, start=start, timeout=10)
            h.drain_until_quiet(process, fd, output)
            # The next key clears the footer; the create refusal must not
            # come back in the body.
            start = len(output)
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=5)
            h.drain_until_quiet(process, fd, output)
            rows = body_rows(output)
            assert not any(REFUSAL in row for row in rows), rows
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description="a modify refused before the editor retires the create refusal",
            interact=interact,
            http_fixtures=fixtures,
            extra_env={"EDITOR": str(editor), "VISUAL": str(editor)},
        )


def guard_refusal_survives_its_withdrawal(executable):
    """The workspace guard refuses a form when the identity probe after the
    editor cannot confirm the workspace. Applying that refusal withdraws the
    workspace reading, and the next refresh reads the same workspace again;
    neither is another workspace, so the refusal stays on the surface."""
    fixtures = schedule.schedule_detail_http_fixtures()
    created = []
    health_reads = []
    lock = threading.Lock()

    def create(body):
        created.append(body)
        return 200, {"result": {"content": [{"type": "text", "text": "created"}]}}

    fixtures[CREATE_PATH] = h.RequestHttpResponse(create)

    with tempfile.TemporaryDirectory() as directory:
        written = Path(directory) / "form-written"
        editor = Path(directory) / "object-form.sh"
        editor.write_text(
            "#!/bin/sh\nprintf %s '{}' > \"$1\"\n: > " + str(written) + "\n")
        editor.chmod(0o755)
        guard_probe = {"answered": False}

        def health():
            # The first identity probe after the editor wrote the form is the
            # guard's; the server does not answer it. Every other probe reads
            # the same workspace.
            with lock:
                if written.exists() and not guard_probe["answered"]:
                    guard_probe["answered"] = True
                    return 503, {"error": "identity probe unavailable"}
                health_reads.append(guard_probe["answered"])
                return 200, {}

        fixtures["/health"] = health

        def interact(process, fd, _slave, output, _base):
            h.palette_go(process, fd, output, b"go schedules", b"Requests: 1")
            h.drain_until_quiet(process, fd, output)
            start = len(output)
            os.write(fd, b"n")
            h.wait_for_output(process, fd, output, GUARD_REFUSAL, start=start, timeout=10)
            h.drain_until_quiet(process, fd, output)
            with lock:
                after_refusal = sum(1 for answered in health_reads if answered)
            # r reads the server again: the same workspace comes back.
            os.write(fd, b"r")
            assert h.wait_for_fixture_state(
                process, fd, output,
                lambda: sum(1 for answered in health_reads if answered) > after_refusal,
                timeout=10), "the refresh after the refusal read no identity"
            start = len(output)
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=5)
            h.drain_until_quiet(process, fd, output)
            rows = body_rows(output)
            assert any(GUARD_REFUSAL in row for row in rows), rows
            assert not created, "a guard-refused form reached the create route"
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description="a workspace-guard refusal survives the refresh that reads the same workspace",
            interact=interact,
            http_fixtures=fixtures,
            extra_env={"EDITOR": str(editor), "VISUAL": str(editor)},
        )


def run(executable):
    object_form_refusal(executable)
    modify_refused_before_the_editor_retires_the_create_refusal(executable)
    guard_refusal_survives_its_withdrawal(executable)
    print("tui schedule form refusal: PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_schedule_form_refusal_pty.py <masc_tui.exe>")
    run(os.path.abspath(sys.argv[1]))
