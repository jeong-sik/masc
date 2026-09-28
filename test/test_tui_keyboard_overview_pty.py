"""Keyboard PTY Dashboard scenarios in the Dune parallel batch."""

import base64
import os
import re
import sys
import threading
import time

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_overview_tasks.ml",
    "bin/masc_tui_overview_goals.ml",
    "bin/masc_tui_overview_providers.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_schedule.ml",
)


def first_use_frames(executable: str) -> None:
    fixtures = keyboard.overview_event_http_fixtures()
    status, empty = keyboard.empty_runtime_resolved_fixture()
    payload = dict(empty)
    names = (
        "antigravity_subscription",
        "claude_code",
        "codex_subscription",
        "deepseek",
        "gemini",
        "kimi",
        "ollama_cloud",
        "openai",
        "zai",
    )
    # One reported window per account, so the Dashboard's usage line counts
    # nine reported scopes.
    observed_at = time.time()
    payload["provider_usage_windows"] = [
        {
            "scope": f"provider:{name}",
            "scope_id": f"scope-{name}",
            "providers": [{"id": name, "display_name": name}],
            "state": "reported",
            "windows": [
                {
                    "limit_id": None,
                    "window": {"kind": "five_hour"},
                    "role": "gates_model_calls",
                    "utilization": {"unit": "percent", "value": 10},
                    "resets_at": None,
                    "observed_at": observed_at,
                }
            ],
        }
        for name in names
    ]
    fixtures[keyboard.RUNTIME_RESOLVED_PATH] = (status, payload)

    requested = threading.Event()
    release = threading.Event()

    def briefing():
        requested.set()
        if not release.wait(30):
            raise AssertionError("the unread briefing fixture was never released")
        return 200, keyboard.overview_event_briefing()

    fixtures["/api/v1/dashboard/briefing"] = briefing

    def interact(process, fd, _slave, output, _base):
        if not requested.wait(10):
            raise AssertionError("the TUI did not request the briefing")

        def capture(state: str, columns: int, needle: bytes) -> bytes:
            frame = keyboard.resize_and_wait(
                process, fd, output, rows=32, columns=columns,
                needle=needle, controls=(keyboard.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = keyboard.screen_text(frame)
            print(
                f"DASHBOARD_FRAME_{state}_{columns}X32_B64="
                f"{base64.b64encode(frame).decode()}"
            )
            print(
                f"DASHBOARD_SCREEN_{state}_{columns}X32_BEGIN\n"
                f"{visible.decode(errors='replace')}\n"
                f"DASHBOARD_SCREEN_{state}_{columns}X32_END"
            )
            return visible

        try:
            # The startup splash stands while the briefing is held, and any key
            # ends it; r only asks for the held briefing again. It is captured
            # at a width neither the harness start (100) nor the checks below
            # use: resizing to the size the terminal already has redraws
            # nothing to wait for.
            capture("SPLASH", 120, b"Dashboard briefing not read yet")
            os.write(fd, b"r")
            for columns in (80, 140):
                unread = capture("UNREAD", columns, b"attention not observed")
                if b"Start here (2 steps)" in unread:
                    raise AssertionError("an unread briefing claimed an empty fleet")
                if b"0 attention items" in unread:
                    raise AssertionError("an unread briefing claimed zero attention items")
        finally:
            release.set()

        keyboard.wait_for_output(
            process, fd, output, b"Start here (2 steps)", start=0, timeout=10
        )
        for columns in (80, 140):
            visible = capture("EMPTY", columns, b"Start here (2 steps)")
            for expected in (
                b"Start here (2 steps)",
                b"masc keeper-create --edit --host 127.0.0.1 --port ",
                b"Open Keepers with 3",
                b"0 attention items",
                b"9/9 quota scopes reported",
            ):
                if expected not in visible:
                    raise AssertionError(
                        f"{columns} columns omitted {expected!r}: {visible!r}"
                    )
            port = re.search(rb"Port: (\d+)", visible)
            if port is None:
                raise AssertionError(f"{columns} columns omitted the server port: {visible!r}")
            command = (
                b"masc keeper-create --edit --host 127.0.0.1 --port "
                + port.group(1)
            )
            if not any(command in line for line in visible.splitlines()):
                raise AssertionError(
                    f"{columns} columns did not target the displayed server: {visible!r}"
                )
        os.write(fd, b"q")

    keyboard.run_terminal_scenario(
        executable, description="first-use Dashboard at 80 and 140 columns",
        interact=interact, http_fixtures=fixtures, workspace="overview-demo",
    )


def unreadable_keeper_listing_has_no_first_use_guide(executable: str) -> None:
    fixtures = keyboard.overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/briefing"] = keyboard.unlisted_keepers_briefing()

    def interact(process, fd, _slave, output, _base):
        keyboard.wait_for_output(process, fd, output, b"(EACCES)", start=0, timeout=10)
        frame = keyboard.resize_and_wait(
            process, fd, output, rows=32, columns=140,
            needle=b"(EACCES)", controls=(keyboard.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        visible = keyboard.screen_text(frame)
        if b"Start here (2 steps)" in visible or b"masc keeper-create --edit" in visible:
            raise AssertionError(f"an unreadable listing claimed an empty fleet: {visible!r}")
        os.write(fd, b"q")

    keyboard.run_terminal_scenario(
        executable, description="unreadable Keeper listing has no first-use guide",
        interact=interact, http_fixtures=fixtures,
    )


if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    keyboard.run_keyboard_regression(executable, group=2)
    first_use_frames(executable)
    unreadable_keeper_listing_has_no_first_use_guide(executable)
    finished = time.monotonic()
    print(
        "tui keyboard overview PTY regression: PASS "
        f"start={started:.6f} end={finished:.6f}"
    )
