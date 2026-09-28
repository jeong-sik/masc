"""Keyboard PTY overview scenarios in the Dune parallel batch."""

import base64
import os
import sys
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

    def interact(process, fd, _slave, output, _base):
        keyboard.wait_for_output(
            process, fd, output, b"Start here (2 steps)", start=0, timeout=10
        )
        for columns in (80, 140):
            frame = keyboard.resize_and_wait(
                process, fd, output, rows=32, columns=columns,
                needle=b"Start here (2 steps)", controls=(keyboard.FULL_REDRAW,)
            )
            visible = keyboard.screen_text(frame)
            for expected in (
                b"Start here (2 steps)",
                b"masc keeper-create --edit",
                b"Goals (0)",
                b"No goal is executing or verifying.",
                b"Nothing needs attention.",
                b"Plan usage",
                b"no usage data",
            ):
                if expected not in visible:
                    raise AssertionError(
                        f"{columns} columns omitted {expected!r}: {visible!r}"
                    )
            if columns == 80 and b"5 more accounts do not fit" not in visible:
                raise AssertionError(f"80 columns hid the usage count: {visible!r}")
            print(f"OVERVIEW_FRAME_{columns}X32_B64={base64.b64encode(frame).decode()}")
            print(f"OVERVIEW_SCREEN_{columns}X32_BEGIN\n{visible.decode(errors='replace')}\n"
                  f"OVERVIEW_SCREEN_{columns}X32_END")
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
    print(f"tui keyboard overview PTY regression: PASS start={started:.6f} end={finished:.6f}")
