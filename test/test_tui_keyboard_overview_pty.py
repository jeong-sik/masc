"""Keyboard PTY Dashboard scenarios in the Dune parallel batch."""

import base64
import json
import os
import sys
from pathlib import Path
import threading
import time

import test_tui_keyboard_input as keyboard




def operator_menu_from_dashboard(executable: str) -> None:
    # The link survives the short Dashboard's body cut, including an empty
    # queue. Its key and its drawn click target reach the same surface.
    for pending in (False, True):
        fixtures = keyboard.overview_event_http_fixtures()
        fixtures[keyboard.KEEPER_ASKS_PATH] = (
            keyboard.keeper_asks_response() if pending
            else (200, {"keeper": None, "open_count": 0, "asks": []})
        )

        def interact(process, fd, _slave, output, _base):
            menu = b"p:Approvals / Questions"
            for columns in (40, 80, 140):
                frame = keyboard.resize_and_wait(
                    process, fd, output, rows=16, columns=columns,
                    needle=menu, controls=(keyboard.FULL_REDRAW,),
                    final_cursor=b"\x1b[?25l",
                )
                rows = keyboard.screen_rows(frame)
                # The first body row follows the title and its divider.
                # Check that row, including its border and optional sidebar,
                # so the footer's repeated label cannot satisfy this.
                menu_row = keyboard.screen_row_of(rows, b"MASC Dashboard") + 2
                if menu not in rows.get(menu_row, b""):
                    raise AssertionError(
                        f"{columns}x16 hid the operator menu body row: {rows!r}"
                    )
                print(f"OPERATOR_MENU_{int(pending)}_{columns}X16_B64="
                      f"{base64.b64encode(frame).decode()}")
                keyboard.press_label_on_screen(
                    process, fd, output, menu,
                    row=menu_row, needle=b"MASC Approvals",
                )
                # Approvals belongs to Work; the current navigation has no
                # global 1 jump. Verify each rendered return, rather than
                # waiting for a Dashboard title after an ignored key.
                keyboard.send_and_wait(process, fd, output, b"\x1b", b"MASC Work")
                keyboard.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            keyboard.resize_and_wait(
                process, fd, output, rows=40, columns=80, needle=menu,
                controls=(keyboard.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
            )
            keyboard.send_and_wait(process, fd, output, b"P", b"MASC Approvals")
            keyboard.send_and_wait(process, fd, output, b"\x1b", b"MASC Work")
            keyboard.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            keyboard.send_and_wait(process, fd, output, b"p", b"MASC Approvals")
            if pending:
                keyboard.wait_for_output(
                    process, fd, output, b"Questions waiting on you", start=0, timeout=10
                )
                keyboard.send_and_wait(process, fd, output, b"a", b"ship the cold-start")
                keyboard.send_and_wait(process, fd, output, b"\x1b", b"MASC Approvals")
            os.write(fd, b"q")

        keyboard.run_terminal_scenario(
            executable, description=f"Dashboard operator menu pending={pending}",
            interact=interact, http_fixtures=fixtures,
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
            # Keep reading frames while the briefing is held so the terminal
            # buffer cannot stop the TUI before its request is observed.
            if not keyboard.wait_for_fixture_event(
                process, fd, output, requested, timeout=10
            ):
                if process.poll() is not None:
                    raise AssertionError(
                        f"the TUI exited before requesting the briefing: {bytes(output)!r}"
                    )
                raise AssertionError("the TUI did not request the briefing")
            # The Dashboard is working from the first frame. Use a width that
            # differs from the harness and the checks below to force a redraw.
            capture("LOADING", 120, b"Connecting to workspace")
            for columns in (80, 140):
                unread = capture("UNREAD", columns, b"Approvals and questions:")
                assert b"not fully read" in unread, unread
                if b"Create a Keeper" in unread:
                    raise AssertionError("an unread briefing claimed an empty fleet")
                if b"No decision is waiting on you." in unread:
                    raise AssertionError("an unread briefing claimed zero attention items")
        finally:
            release.set()

        keyboard.wait_for_output(
            process, fd, output, b"Create a Keeper", start=0, timeout=10
        )
        for columns in (80, 140):
            visible = capture("EMPTY", columns, b"Create a Keeper")
            for expected in (b"Create a Keeper", b"Continue", b"Health:"):
                if expected not in visible:
                    raise AssertionError(f"{columns} columns omitted {expected!r}: {visible!r}")
            for forbidden in (b"quota scopes reported", b"Plan usage", b"linked tasks", b"Start here"):
                if forbidden in visible:
                    raise AssertionError(f"Home repeated a detail panel: {visible!r}")
        os.write(fd, b"q")

    keyboard.run_terminal_scenario(
        executable, description="first-use Dashboard at 80 and 140 columns",
        interact=interact, http_fixtures=fixtures, workspace="overview-demo",
        prepare_workspace=lambda base: [p.unlink() for p in (Path(base) / ".masc" / "keepers").glob("*.json")],
    )


def unreadable_keeper_listing_has_no_first_use_guide(executable: str) -> None:
    fixtures = keyboard.overview_event_http_fixtures()
    fixtures["/api/v1/dashboard/briefing"] = keyboard.unlisted_keepers_briefing()

    def interact(process, fd, _slave, output, _base):
        keyboard.wait_for_output(process, fd, output, b"Keepers unlisted: EACCES", start=0, timeout=10)
        frame = keyboard.resize_and_wait(
            process, fd, output, rows=32, columns=140,
            needle=b"Keepers unlisted: EACCES", controls=(keyboard.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        visible = keyboard.screen_text(frame)
        if b"Create a Keeper" in visible or b"masc keeper-create --edit" in visible:
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
        (None, None, b"MASC Dashboard"),
        ("overview", None, b"MASC Dashboard"),
        ("last", None, b"Could not open last chat (no saved Keeper). Showing Dashboard."),
        ("last", "alpha", "Keepers ▸ alpha ▸ chat".encode()),
        ("last", "beta", "Keepers ▸ beta ▸ chat".encode()),
        ("last", "last", "Keepers ▸ last ▸ chat".encode()),
        ("keeper", "alpha", "Keepers ▸ alpha ▸ chat".encode()),
        ("keeper", "missing",
         b"Could not open chat with missing (Keeper not found). Showing Dashboard."),
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
            # Home actions exist while the initial Keeper read is still in
            # flight. A fallback must wait for that read's actual reason,
            # not the earlier loading frame that already says Continue.
            needles = (expected,) if chat or mode in ("last", "keeper") else (b"Continue",)
            for needle in needles:
                keyboard.wait_for_output(
                    process, fd, output, needle, start=0, timeout=10
                )
            # The needle can arrive before the rest of its frame, and that
            # frame rewrites only the rows that changed: the title can sit in
            # an earlier one. So wait for the frame's end and replay every row
            # painted up to it (screen_text starts at the last full redraw).
            needle_end = max(keyboard.end_of_needle(output, needle, 0) for needle in needles)
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
                continuation = next((i for i, row in enumerate(rows) if b"Continue" in row), None)
                if mode in ("last", "keeper") and (reason is None or continuation is None or reason >= continuation):
                    raise AssertionError(f"fallback reason was not before the Home actions: {visible!r}")
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
            if mode == "keeper" and target == "alpha":
                home = keyboard.palette_go(
                    process, fd, output, b"go dashboard", b"Choose a Keeper"
                )
                visible_home = keyboard.screen_text(home)
                if b"Continue with alpha" in visible_home:
                    raise AssertionError(
                        f"fixed startup Keeper was remembered as a chat: {visible_home!r}"
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
    operator_menu_from_dashboard(executable)
    first_use_frames(executable)
    unreadable_keeper_listing_has_no_first_use_guide(executable)
    opening_boot_frames(executable)
    finished = time.monotonic()
    print(
        "tui keyboard overview PTY regression: PASS "
        f"start={started:.6f} end={finished:.6f}"
    )
