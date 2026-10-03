"""The runtime.toml account form, pressed for real.

[a] on System > runtime.toml opens the form over the file the pane shows. The
scenario types a home another Codex provider already signs in at and reads
the refusal on the form, fixes it, and saves. While the form stands open the
file on the server gains a line, the way another client or a keeper would
write it; the save has to carry that line, because the form declares against
runtime.toml as the server holds it at submit, not as it was opened. The main
judgement is the text the save posts, read whole at the end. After the save
the form stays on the sign-in command: [y] sends it whole through OSC 52, and
Enter closes the form, so the runner's [q] quits again.
"""
import base64
import json
import os
import sys
import threading
import time

import test_tui_keyboard_input as h



RAW_PATH = "/api/v1/runtime/config/raw"
PREVIEW_PATH = "/api/v1/runtime/config/raw/preview"

SOURCE = """# operator notes stay where they are
[providers.codex_subscription]
display-name = "Codex"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

[providers.codex_acct1]
display-name = "Codex one"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/codex-one"

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true

[codex_subscription."gpt-5.6"]
max-concurrent = 2

[codex_acct1."gpt-5.6"]
"""

# Written to the server's copy after the form opens.
MEANWHILE = "# added while the form was open\n"

# The sign-in the saved form copies for the home the scenario types.
SIGN_IN = b"(export CODEX_HOME='/tmp/codex-second' && codex login)"


def commit_receipt() -> dict[str, object]:
    """The shape Masc_tui_runtime_config_receipt.decode reads; the same one
    test_tui_runtime_lane_editor.py serves."""
    return {
        "ok": True,
        "state": "committed",
        "commit": {
            "source_revision": "source-8",
            "order": "8",
            "durability": "durable",
            "warnings": [],
        },
        "application": {
            "operation": "raw",
            "routing": {
                "status": "applied",
                "requires_restart": False,
                "applied_at": "2026-09-28T04:00:00Z",
            },
            "keeper_overlay": {
                "status": "not_configured",
                "configured_count": 0,
                "requires_restart": False,
                "pending_keys": [],
                "applied_keys": [],
                "preempted_keys": [],
                "applied_at": None,
            },
            "skills": {
                "state": "unchanged",
                "input_source_revision": "source-8",
                "snapshot_revision": "snapshot-8",
                "catalog_revision": "catalog-8",
                "config_state": "configured",
            },
            "exact_output_registry": {
                "status": "applied",
                "requires_restart": False,
                "targets": "runtime_bindings",
            },
        },
    }


class ServerCopy:
    """runtime.toml as the fixture server holds it: GET reads it, a save
    replaces it."""

    def __init__(self) -> None:
        self.text = SOURCE
        self.lock = threading.Lock()

    def append(self, line: str) -> None:
        with self.lock:
            self.text += line

    def raw(self, body: bytes):
        with self.lock:
            if body:
                self.text = json.loads(body)["source_text"]
                return 200, commit_receipt()
            return 200, {
                **h.runtime_config_read_metadata(),
                "path": "/workspace/config/runtime.toml",
                "source_text": self.text,
            }


def run(executable: str) -> None:
    server = ServerCopy()
    fixtures = h.overview_event_http_fixtures()
    fixtures[RAW_PATH] = h.RequestHttpResponse(server.raw)
    fixtures[PREVIEW_PATH] = (
        200,
        {"ok": True, "can_save": True, "validation": {"valid": True, "issues": []}},
    )
    requests: list[tuple[str, bytes]] = []

    def interact(process, fd, _slave_fd, output, _base_path) -> None:
        h.tab_until(process, fd, output, b"MASC System")
        h.wait_for_output(process, fd, output, b"codex_acct1", start=0, timeout=5.0)

        h.send_and_wait(process, fd, output, b"a", b"codex_subscription_2")
        screen = h.screen_text(bytes(output))
        if b"Enter:next / save" not in screen:
            raise AssertionError(f"the form's footer is not drawn: {screen!r}")

        # Someone else writes runtime.toml while the form is open.
        server.append(MEANWHILE)

        # Provider, then id, then a home codex_acct1 already signs in at.
        h.send_and_wait(process, fd, output, b"\r\r/tmp/codex-one", b"CODEX_HOME='/tmp/codex-one'")
        h.send_and_wait(process, fd, output, b"\r", b"already signs in at /tmp/codex-one")
        if any(path == RAW_PATH for path, _ in requests):
            raise AssertionError("a refused declaration was saved")

        h.send_and_wait(process, fd, output, b"\x7f\x7f\x7fsecond", b"CODEX_HOME='/tmp/codex-second'")
        h.send_and_wait(process, fd, output, b"\r", b"runtime.toml saved")
        # The fixture server records a POST after answering it, so the screen
        # can say "saved" a moment before the save is in [requests].
        deadline = time.monotonic() + 5.0
        while not any(path == RAW_PATH for path, _ in requests) and time.monotonic() < deadline:
            time.sleep(0.05)

        saves = [json.loads(body)["source_text"] for path, body in requests if path == RAW_PATH]
        previews = [json.loads(body)["source_text"] for path, body in requests if path == PREVIEW_PATH]
        if len(saves) != 1 or previews != saves:
            raise AssertionError(f"one previewed save expected: saves={saves!r} previews={previews!r}")
        saved = saves[0]
        if not saved.startswith(SOURCE + MEANWHILE):
            raise AssertionError(f"the save did not keep the line written meanwhile: {saved!r}")
        for needle in (
            '[providers."codex_subscription_2"]',
            'account-home = "/tmp/codex-second"',
            '["codex_subscription_2"."gpt-5.6"]',
            "max-concurrent = 2",
        ):
            if needle not in saved[len(SOURCE + MEANWHILE):]:
                raise AssertionError(f"the appended provider lacks {needle!r}: {saved!r}")

        # The form stays open on the command and names its copy key under
        # it: the save notice leads the footer, whose fitter keeps only the
        # way out. Then [y] copies the command whole.
        h.wait_for_output(process, fd, output, b"  y:copy sign-in", start=0, timeout=5.0)
        rows = h.screen_rows(bytes(output))
        command_row = h.screen_row_of(rows, SIGN_IN)
        key_row = h.screen_row_of(rows, b"y:copy sign-in")
        if not 0 <= command_row < key_row:
            raise AssertionError(f"the copy key is not drawn under the command: {h.screen_text(bytes(output))!r}")
        osc52 = b"\x1b]52;c;" + base64.b64encode(SIGN_IN) + b"\x07"
        h.send_and_wait(process, fd, output, b"y", osc52)
        # Enter closes it. While it stood open [q] was ignored, so the runner's
        # quit below times out unless the form closed.
        os.write(fd, b"\r")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="The runtime.toml account form declares against the file at submit",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("runtime account form: PASS")
