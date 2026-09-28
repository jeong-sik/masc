"""Keyboard PTY overview scenarios in the Dune parallel batch."""

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
    payload["provider_usage_windows"] = [
        {
            "scope": f"provider:{name}",
            "providers": [name],
            "state": "not_reported_since_start",
            "windows": [],
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
                f"OVERVIEW_FRAME_{state}_{columns}X32_B64="
                f"{base64.b64encode(frame).decode()}"
            )
            print(
                f"OVERVIEW_SCREEN_{state}_{columns}X32_BEGIN\n"
                f"{visible.decode(errors='replace')}\n"
                f"OVERVIEW_SCREEN_{state}_{columns}X32_END"
            )
            return visible

        try:
            for columns in (80, 140):
                unread = capture(
                    "UNREAD", columns, b"Overview briefing not read yet"
                )
                if b"Start here (2 steps)" in unread:
                    raise AssertionError("an unread briefing claimed an empty fleet")
        finally:
            release.set()

        keyboard.wait_for_output(
            process, fd, output, b"Start here (2 steps)", start=0, timeout=10
        )
        for columns in (80, 140):
            visible = capture("EMPTY", columns, b"Start here (2 steps)")
            for expected in (
                b"Start here (2 steps)",
                b"masc keeper-create --edit",
                b"Goals (0)",
                b"No goal is executing or verifying.",
                b"Nothing needs attention.",
                b"Plan usage",
                b"no usage data",
                b"Approvals: 0?",
            ):
                if expected not in visible:
                    raise AssertionError(
                        f"{columns} columns omitted {expected!r}: {visible!r}"
                    )
            count = re.search(rb"Plan usage \((\d+)/(\d+) accounts shown\)", visible)
            if count is None or tuple(int(part) for part in count.groups()) != (4, 9):
                raise AssertionError(f"{columns} columns did not show 4/9 accounts: {visible!r}")
            if b"5 more accounts do not fit at this height." not in visible:
                raise AssertionError(f"{columns} columns hid the usage count: {visible!r}")
            left = [line.split(b"\xe2\x94\x82", 1)[0].strip() for line in visible.splitlines()]
            attention = next(i for i, line in enumerate(left) if b"Attention (0)" in line)
            tasks = next(i for i, line in enumerate(left) if b"Tasks (0 open)" in line)
            if left[attention + 1] or left[tasks - 1] or left[tasks + 1]:
                raise AssertionError(f"{columns} columns lost approved section spacing: {visible!r}")
        os.write(fd, b"q")

    keyboard.run_terminal_scenario(
        executable, description="first-use overview at 80 and 140 columns",
        interact=interact, http_fixtures=fixtures,
    )


if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    keyboard.run_keyboard_regression(executable, group=2)
    first_use_frames(executable)
    finished = time.monotonic()
    print(
        "tui keyboard overview PTY regression: PASS "
        f"start={started:.6f} end={finished:.6f}"
    )
