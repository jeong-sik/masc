"""The runtime.toml account removal, pressed for real.

[D] on Config > runtime.toml opens the removal screen over the file the pane
shows. The first account is the one [runtime].default names, so the screen
refuses it and Enter saves nothing. The second is removed: the screen lists
its tables, the lane candidate it leaves and the keeper that goes back to the
default. While the screen stands open the server's copy gains a second keeper
assigned to that account. The first Enter must not save a removal the
operator did not see; it shows the new change, and the second Enter saves.
The main judgement is the text the save posts, read whole at the end.
"""
import json
import os
import sys
import threading
import time

import test_tui_keyboard_input as h
from test_tui_runtime_account_form_pty import commit_receipt

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_runtime_account_removal.ml",
    "lib/runtime/runtime_account_removal.ml",
)

RAW_PATH = "/api/v1/runtime/config/raw"
PREVIEW_PATH = "/api/v1/runtime/config/raw/preview"

SOURCE = """# operator notes stay where they are
[runtime]
default = "codex_subscription.gpt-5.6"

[runtime.lanes.coding]
candidates = ["codex_acct1.gpt-5.6", "codex_subscription.gpt-5.6"]

[runtime.assignments]
sangsu = "codex_acct1.gpt-5.6"

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

ASSIGNED = 'sangsu = "codex_acct1.gpt-5.6"\n'
# Written into the server's copy while the screen is open.
MEANWHILE = 'later = "codex_acct1.gpt-5.6"\n'


class ServerCopy:
    """runtime.toml as the fixture server holds it: GET reads it, a save
    replaces it."""

    def __init__(self) -> None:
        self.text = SOURCE
        self.lock = threading.Lock()

    def assign_meanwhile(self) -> None:
        with self.lock:
            self.text = self.text.replace(ASSIGNED, ASSIGNED + MEANWHILE)

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

    def saves() -> list[str]:
        return [json.loads(body)["source_text"] for path, body in requests if path == RAW_PATH and body]

    def interact(process, fd, _slave_fd, output, _base_path) -> None:
        h.tab_until(process, fd, output, b"MASC Config")
        h.wait_for_output(process, fd, output, b"codex_acct1", start=0, timeout=5.0)

        # The first account is the default's: refused, and Enter saves nothing.
        h.send_and_wait(process, fd, output, b"D", b"[runtime].default is codex_subscription")
        screen = h.screen_text(bytes(output))
        if b"Enter:remove & save" not in screen:
            raise AssertionError(f"the removal footer is not drawn: {screen!r}")
        os.write(fd, b"\r")

        # The second account: its tables, the lane it leaves, the keeper.
        h.send_and_wait(process, fd, output, b"\x1b[C", b"keeper sangsu")
        for needle in (b"[providers.codex_acct1]", b"lane coding", b"/tmp/codex-one"):
            if needle not in h.screen_text(bytes(output)):
                raise AssertionError(f"the removal does not list {needle!r}")

        # Another keeper is assigned to it before Enter: shown, not saved.
        server.assign_meanwhile()
        h.send_and_wait(process, fd, output, b"\r", b"keeper later")
        if saves():
            raise AssertionError(f"a removal the operator had not seen was saved: {saves()!r}")

        h.send_and_wait(process, fd, output, b"\r", b"runtime.toml saved")
        # The fixture server records a POST after answering it.
        deadline = time.monotonic() + 5.0
        while not saves() and time.monotonic() < deadline:
            time.sleep(0.05)
        posted = saves()
        previews = [json.loads(body)["source_text"] for path, body in requests if path == PREVIEW_PATH]
        if len(posted) != 1 or previews != posted:
            raise AssertionError(f"one previewed save expected: saves={posted!r} previews={previews!r}")
        saved = posted[0]
        for gone in ("[providers.codex_acct1]", '[codex_acct1."gpt-5.6"]', ASSIGNED, MEANWHILE):
            if gone in saved:
                raise AssertionError(f"the save still carries {gone!r}: {saved!r}")
        for kept in (
            "# operator notes stay where they are",
            '"codex_subscription.gpt-5.6"',
            "[providers.codex_subscription]",
            '[codex_subscription."gpt-5.6"]\nmax-concurrent = 2',
        ):
            if kept not in saved:
                raise AssertionError(f"the save lost {kept!r}: {saved!r}")
        if '"codex_acct1.gpt-5.6"' in saved:
            raise AssertionError(f"a route to the removed account is left: {saved!r}")
        # The screen closed with the save, so the runner's [q] quits.

    h.run_terminal_scenario(
        executable,
        description="The runtime.toml account removal shows what it changes before it saves",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("runtime account removal: PASS")
