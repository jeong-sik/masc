"""Keyboard PTY overview scenarios in the Dune parallel batch."""

import base64
import json
import os
import re
import sys
from pathlib import Path
import threading
import time

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_config.ml",
    "bin/masc_tui_types.ml",
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
    # One reported window per account, so each account draws one row. An
    # account with no report draws none, and the budget below counts rows.
    observed_at = time.time()
    payload["provider_usage_windows"] = [
        {
            "scope": f"provider:{name}",
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
            # The splash candle keeps drawing while the briefing is held, so
            # the wait reads the PTY; an unread one fills and stops the TUI.
            if not keyboard.wait_for_fixture_event(
                process, fd, output, requested, timeout=10
            ):
                if process.poll() is not None:
                    raise AssertionError(
                        f"the TUI exited before requesting the briefing: {bytes(output)!r}"
                    )
                raise AssertionError("the TUI did not request the briefing")
            for columns in (80, 140):
                unread = capture(
                    "UNREAD", columns, b"Overview briefing not read yet"
                )
                if b"Start here (2 steps)" in unread:
                    raise AssertionError("an unread briefing claimed an empty fleet")
                if b"Attention (0)" in unread:
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
                b"Goals (0)",
                b"No goal is executing or verifying.",
                b"Nothing needs attention.",
                b"Plan usage",
                b"10%",
                b"Approvals: 0?",
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
            count = re.search(rb"Plan usage \((\d+)/(\d+) accounts shown\)", visible)
            if count is None or tuple(int(part) for part in count.groups()) != (6, 9):
                raise AssertionError(f"{columns} columns did not show 6/9 accounts: {visible!r}")
            if b"3 more accounts do not fit at this height." not in visible:
                raise AssertionError(f"{columns} columns hid the usage count: {visible!r}")
            left = [line.split(b"\xe2\x94\x82", 1)[0].strip() for line in visible.splitlines()]
            attention = next(i for i, line in enumerate(left) if b"Attention (0)" in line)
            tasks = next(i for i, line in enumerate(left) if b"Tasks (0 open)" in line)
            if left[attention + 1] or left[tasks - 1] or left[tasks + 1]:
                raise AssertionError(f"{columns} columns lost approved section spacing: {visible!r}")
        narrow = keyboard.resize_and_wait(
            process, fd, output, rows=20, columns=80,
            needle=b"Plan usage", controls=(keyboard.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        narrow_text = keyboard.screen_text(narrow)
        if b"Start here (2 steps)" in narrow_text:
            raise AssertionError(f"a partial first-use guide was drawn: {narrow_text!r}")
        if b"Plan usage" not in narrow_text or b"antigravity_subscription" not in narrow_text:
            raise AssertionError(f"suppressed guide did not free provider rows: {narrow_text!r}")
        os.write(fd, b"q")

    keyboard.run_terminal_scenario(
        executable, description="first-use overview at 80 and 140 columns",
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


def opening_boot_frames(executable: str) -> None:
    # The remembered target is written through Runtime's full config validator.
    runtime = (
        '[providers.local]\nprotocol = "openai-compatible-http"\n'
        'endpoint = "http://127.0.0.1:1/v1"\n'
        '[models.sample]\napi-name = "sample"\nmax-context = 1024\n'
        '[models.sample.capabilities]\nmax-output-tokens = 1024\n'
        '[local.sample]\n[runtime]\ndefault = "local.sample"\n'
    )
    cases = (
        (None, None, b"MASC Overview"),
        ("overview", None, b"MASC Overview"),
        ("last", None, b"Could not open last chat (no saved Keeper). Showing Overview."),
        ("last", "alpha", "Keepers ▸ alpha ▸ chat".encode()),
        ("last", "beta", "Keepers ▸ beta ▸ chat".encode()),
        ("last", "last", "Keepers ▸ last ▸ chat".encode()),
        ("keeper", "alpha", "Keepers ▸ alpha ▸ chat".encode()),
        ("keeper", "missing",
         b"Could not open chat with missing (Keeper not found). Showing Overview."),
    )
    for mode, target, expected in cases:
        def prepare(base_path: str) -> None:
            config = Path(base_path) / ".masc" / "config"
            config.mkdir(parents=True, exist_ok=True)
            lines = ["[tui]"]
            if mode is not None:
                lines.append(f'opening = "{mode}"')
            if target is not None:
                lines.append(f'opening_keeper = "{target}"')
            (config / "runtime.toml").write_text(
                runtime + "\n".join(lines) + "\n", encoding="utf-8"
            )
            if mode == "last" and target is None:
                for name in ("alpha", "beta"):
                    (Path(base_path) / ".masc" / "keepers" / f"{name}.json").unlink()
            if target == "last":
                (Path(base_path) / ".masc" / "keepers" / "last.json").write_text(
                    json.dumps(keyboard.keeper_metadata("last")), encoding="utf-8"
                )

        def interact(process, fd, _slave, output, base_path):
            chat = expected.startswith(b"Keepers ")
            needle = expected if chat else b"Goals ("
            keyboard.wait_for_output(
                process, fd, output, needle, start=0, timeout=10
            )
            # The needle can arrive before the rest of its frame, and that
            # frame rewrites only the rows that changed: the title can sit in
            # an earlier one. So wait for the frame's end and replay every row
            # painted up to it (screen_text starts at the last full redraw).
            needle_end = keyboard.end_of_needle(output, needle, 0)
            keyboard.wait_for_output(
                process, fd, output, keyboard.FRAME_END, start=needle_end, timeout=3.0
            )
            drawn = bytes(output)
            frame_end = drawn.find(keyboard.FRAME_END, needle_end) + len(keyboard.FRAME_END)
            visible = keyboard.screen_text(drawn[:frame_end])
            if expected not in visible:
                raise AssertionError(
                    f"opening={mode!r}, target={target!r} omitted {expected!r}: {visible!r}"
                )
            if not chat:
                rows = visible.splitlines()
                reason = next((i for i, row in enumerate(rows) if expected in row), None)
                goals = next((i for i, row in enumerate(rows) if b"Goals (" in row), None)
                if mode in ("last", "keeper") and (reason is None or goals is None or reason >= goals):
                    raise AssertionError(f"fallback reason was not the first Overview row: {visible!r}")
            if mode == "last" and target is None:
                narrow = keyboard.resize_and_wait(
                    process, fd, output, rows=20, columns=80,
                    needle=expected, controls=(keyboard.FULL_REDRAW,),
                    final_cursor=b"\x1b[?25l",
                )
                if expected not in keyboard.screen_text(narrow):
                    raise AssertionError("the last-chat fallback reason disappeared at 80x20")
            if chat:
                start = len(output)
                os.write(fd, b"\x1b")
                keyboard.wait_for_output(
                    process, fd, output, b":settings", start=start, timeout=3
                )
            if mode == "last" and target == "alpha":
                keyboard.select_keeper_row(process, fd, output, b"beta")
                keyboard.send_and_wait(
                    process, fd, output, b"m", "Keepers ▸ beta ▸ chat".encode()
                )
                stored = (Path(base_path) / ".masc" / "config" / "runtime.toml").read_text(
                    encoding="utf-8"
                )
                if 'opening_keeper = "beta"' not in stored.splitlines():
                    raise AssertionError(f"last chat target was not stored: {stored!r}")
                keyboard.send_and_wait(process, fd, output, b"\x1b", b":settings")
            os.write(fd, b"q")

        fixtures = (
            keyboard.overview_event_http_fixtures()
            if target is None else keyboard.keeper_runtime_http_fixtures()
        )
        if target == "last":
            status, roster = fixtures["/api/v1/gate/keepers?detailed=true"]
            assert status == 200
            roster["keepers"][0]["name"] = "last"
            roster["keepers"][0]["meta"] = keyboard.keeper_roster_meta("last")
        keyboard.run_terminal_scenario(
            executable,
            description=f"opening {mode or 'absent'} {target or 'unset'}",
            interact=interact,
            http_fixtures=fixtures,
            prepare_workspace=prepare,
            extra_env={"MASC_CONFIG_DIR": ""},
            starts_in_chat=expected.startswith(b"Keepers "),
            terminal_cols=80,
        )


if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    keyboard.run_keyboard_regression(executable, group=2)
    first_use_frames(executable)
    unreadable_keeper_listing_has_no_first_use_guide(executable)
    opening_boot_frames(executable)
    finished = time.monotonic()
    print(
        "tui keyboard overview PTY regression: PASS "
        f"start={started:.6f} end={finished:.6f}"
    )
