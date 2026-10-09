"""A browser login keeps being polled after the operator leaves the Identity tab.

Consent happens in a browser, and the callback lands on the server, not here.
The tick asks the Keeper's provider inventory again while a login this TUI
started is outstanding -- for every Keeper that waits and from any surface --
and stops once the exact login attempt completes. Before #41494's port it asked only for
the selected Keeper on its Identity tab, so a login finished while the
operator was on Home never showed.
"""
import os
import stat
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import tui_keyboard_harness as h

ATTACHED_TOOLS_PATH = "/api/v1/keepers/oauth/attached-tools"
ATTEMPT_STATUS_PATH = "/api/v1/keepers/oauth/attempt-status"
LOGIN_PATH = "/api/v1/keepers/alpha/oauth-login"
IDENTITY_TAB_STEPS = 6  # Info -> Items -> Sandbox -> Settings -> Secrets -> GitHub -> Identity


def no_browser_path(root: Path) -> str:
    """A PATH whose `open`/`xdg-open` succeed without opening anything: the
    TUI opens the consent URL itself, and a test must not open a browser."""
    stubs = root / "no-browser"
    stubs.mkdir()
    for name in ("open", "xdg-open"):
        stub = stubs / name
        stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return f"{stubs}{os.pathsep}{os.environ.get('PATH', '')}"


def run(executable):
    lock = threading.Lock()
    attached = threading.Event()
    completed_status_read = threading.Event()
    terminal_catalog_read = threading.Event()
    polls = []  # (keeper, surface, answered attached) for each inventory read
    surface = {"name": "start"}
    attempt = {"id": "fixture-attempt-slack", "deadline": 0.0}

    def inventory(path):
        keeper = path.split("keeper=", 1)[1].split("&", 1)[0] if "keeper=" in path else ""
        row = {"provider": "slack", "provider_label": "Slack"}
        answered_attached = attached.is_set()
        if answered_attached:
            row["tools"] = ["sendMessage"]
        with lock:
            polls.append((keeper, surface["name"], answered_attached))
        if keeper == "alpha" and answered_attached and completed_status_read.is_set():
            terminal_catalog_read.set()
        return 200, {"providers": [row]}

    def login(_body):
        attempt["deadline"] = time.time() + 600.0
        return 200, {"authorize_url": "https://consent.invalid/slack", "provider": "slack",
                     "expires_at": attempt["deadline"], "attempt_id": attempt["id"]}

    def attempt_status(path):
        scope = parse_qs(urlsplit(path).query)
        if scope != {"keeper": ["alpha"], "provider": ["slack"], "attempt_id": [attempt["id"]]}:
            return 200, {"kind": "unavailable"}
        if attached.is_set():
            completed_status_read.set()
            return 200, {"kind": "completed", "credential_publication": "published",
                         "tool_discovery": {"kind": "discovered", "count": 1}}
        return 200, {"kind": "awaiting_consent", "expires_at": attempt["deadline"]}

    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[ATTACHED_TOOLS_PATH] = h.PathHttpResponse(inventory)
    fixtures[ATTEMPT_STATUS_PATH] = h.PathHttpResponse(attempt_status)
    fixtures[LOGIN_PATH] = h.RequestHttpResponse(login)

    def alpha_polls_on(name, *, attached_answer=None):
        with lock:
            return sum(1 for keeper, where, answer in polls
                       if keeper == "alpha" and where == name
                       and (attached_answer is None or answer == attached_answer))

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        for _ in range(IDENTITY_TAB_STEPS):
            os.write(fd, b"]")
            h.drain_until_quiet(process, fd, output)
        h.wait_for_output(process, fd, output, b"Slack", start=0, timeout=10)
        with lock:
            surface["name"] = "identity"
        h.send_and_wait(process, fd, output, b"1", b"consent.invalid")
        # Leave the tab the old poll was tied to.
        h.palette_go(process, fd, output, b"go dashboard", b"MASC Dashboard")
        with lock:
            surface["name"] = "dashboard"
        # Still waiting: the tick asks for alpha from Home.
        assert h.wait_for_fixture_state(
            process, fd, output, lambda: alpha_polls_on("dashboard") >= 1, timeout=10
        ), ("a pending login was not polled once the operator left the Identity tab", polls)
        attached.set()
        # The completed handle retires the wait after a published inventory read ...
        assert h.wait_for_fixture_state(
            process, fd, output,
            lambda: terminal_catalog_read.is_set()
                    and alpha_polls_on("dashboard", attached_answer=True) >= 1, timeout=10
        ), ("the attached answer was never read from Home", polls)
        # ... and no further tick asks again (six ticks at this cadence).
        after = alpha_polls_on("dashboard")
        assert not h.wait_for_fixture_state(
            process, fd, output, lambda: alpha_polls_on("dashboard") > after, timeout=3
        ), ("an attached login kept being polled", polls)
        os.write(fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-tui-no-browser-") as stubs:
        h.run_terminal_scenario(
            executable,
            description="a pending browser login is polled from any surface until it attaches",
            interact=interact,
            http_fixtures=fixtures,
            extra_env={"PATH": no_browser_path(Path(stubs))},
            # The poll rides the tick; the scenario waits on ticks, so it runs a
            # short cadence. Nothing here was withdrawn by an authority change.
            refresh=0.5,
        )
    print("tui identity login poll: PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_identity_login_poll_pty.py <masc_tui.exe>")
    run(os.path.abspath(sys.argv[1]))
