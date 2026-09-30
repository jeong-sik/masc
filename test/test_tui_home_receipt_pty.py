"""Home conversation receipts, including a real same-workspace Linux restart."""

import os
from pathlib import Path
import signal
import sys
import tomllib

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_config.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_loader.ml",
)

RUNTIME = (
    '[providers.local]\nprotocol = "openai-compatible-http"\n'
    'endpoint = "http://127.0.0.1:1/v1"\n'
    '[models.sample]\napi-name = "sample"\nmax-context = 1024\n'
    '[models.sample.capabilities]\nmax-output-tokens = 1024\n'
    '[local.sample]\n[runtime]\ndefault = "local.sample"\n'
)


def config_path(base):
    return Path(base) / ".masc" / "config" / "runtime.toml"


def prepare(text):
    def seed(base):
        path = config_path(base)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(RUNTIME + "[tui]\n" + text, encoding="utf-8")
    return seed


def settings(base):
    return tomllib.loads(config_path(base).read_text(encoding="utf-8"))["tui"]


def fixtures():
    responses = h.keeper_runtime_http_fixtures()
    for name in ("alpha", "beta"):
        responses[f"/api/v1/keepers/{name}/chat/history"] = (200, [])
        responses[f"/api/v1/keepers/{name}/chat/history/page"] = (
            200, {"messages": [], "has_more": False, "next_before": None}
        )
    return responses


def home(process, fd, output, needle):
    h.read_available(fd, output)
    current = h.screen_text(bytes(output))
    if b"MASC Dashboard" in current and needle in current:
        return bytes(output)
    return h.palette_go(process, fd, output, b"go dashboard", needle)


def visit_beta(process, fd, output):
    h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"beta")
    h.send_and_wait(process, fd, output, b"m", "Keepers ▸ beta ▸ chat".encode())
    h.send_and_wait(process, fd, output, b"\x1b", b":settings")


def restart(process, fd, slave, output, check):
    """Resume the same terminal-owning shell for its second binary launch."""
    start = len(output)
    os.write(fd, b"qq")
    h.wait_for_stop(process, fd, output, timeout=5,
                    description="first receipt TUI exit before restart")
    if b"Goodbye!" not in output[start:]:
        raise AssertionError("first TUI did not finish before restart")
    # The shell keeps the controlling terminal, argv, stdin and environment.
    restarted = h.PtyOutput()
    restarted.pid = process.pid
    os.kill(process.pid, signal.SIGCONT)
    check(process, fd, restarted)
    home(process, fd, restarted, b"MASC Dashboard")
    end = len(restarted)
    os.write(fd, b"qq")
    h.wait_for_output(process, fd, restarted, b"Goodbye!", start=end, timeout=5)
    # Keep only launch two's bytes for the outer harness's final exit checks.
    output.clear()
    output.extend(restarted)
    # The outer harness consumes the second stop, checks termios, then resumes
    # this same wrapper to exit. No exit-confirmation bytes remain to send.


def persistence(executable, mode):
    initial = f'opening = "{mode}"\nopening_keeper = "alpha"\n'

    def interact(process, fd, slave, output, base):
        before = config_path(base).read_bytes()
        if mode != "overview":
            h.wait_for_output(process, fd, output,
                              "Keepers ▸ alpha ▸ chat".encode(), start=0, timeout=10)
            h.send_and_wait(process, fd, output, b"\x1b", b":settings")
        home(process, fd, output, b"Choose a Keeper" if mode != "last"
             else b"Continue with alpha")
        if config_path(base).read_bytes() != before:
            raise AssertionError("automatic boot changed the receipt/config")
        visit_beta(process, fd, output)
        stored = settings(base)
        if stored.get("last_chat_keeper") != "beta":
            raise AssertionError(f"explicit beta visit not recorded: {stored}")
        expected_fixed = "beta" if mode == "last" else "alpha"
        if stored.get("opening_keeper") != expected_fixed:
            raise AssertionError(f"opening target changed incorrectly: {stored}")
        home(process, fd, output, b"Continue with beta")
        committed = config_path(base).read_bytes()

        def check(child, child_fd, child_output):
            target = "beta" if mode == "last" else "alpha"
            if mode != "overview":
                h.wait_for_output(child, child_fd, child_output,
                                  f"Keepers ▸ {target} ▸ chat".encode(),
                                  start=0, timeout=10)
                h.send_and_wait(child, child_fd, child_output, b"\x1b", b":settings")
            else:
                h.wait_for_output(child, child_fd, child_output, b"MASC Dashboard",
                                  start=0, timeout=30)
            home(child, child_fd, child_output, b"Continue with beta")
            if config_path(base).read_bytes() != committed:
                raise AssertionError("restart overwrote explicit beta receipt")

        restart(process, fd, slave, output, check)

    h.run_terminal_scenario(
        executable, description=f"Home receipt same workspace restart {mode}",
        interact=interact, prepare_workspace=prepare(initial),
        http_fixtures=fixtures(), confirm_exit=b"",
        launch_count=2,
        extra_env={"MASC_CONFIG_DIR": ""}, starts_in_chat=mode != "overview",
        terminal_cols=140,
    )


def unavailable_receipts(executable):
    for receipt, needle in (
        ("42", b"Conversation history unavailable"),
        ('"deleted"', b"Last conversation deleted unavailable"),
    ):
        def interact(process, fd, _slave, output, base):
            h.wait_for_output(process, fd, output, needle, start=0, timeout=10)
            frame = h.resize_and_wait(process, fd, output, rows=32, columns=140,
                                      needle=needle, controls=(h.FULL_REDRAW,))
            if b"Continue with" in h.screen_text(frame):
                raise AssertionError("unreadable/deleted receipt offered continuation")
            if settings(base)["last_chat_keeper"] != tomllib.loads(
                f"value = {receipt}"
            )["value"]:
                raise AssertionError("boot rewrote an unavailable receipt")
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable, description=f"Home unavailable receipt {receipt}",
            interact=interact,
            prepare_workspace=prepare(f'opening = "overview"\nlast_chat_keeper = {receipt}\n'),
            http_fixtures=fixtures(),
            extra_env={"MASC_CONFIG_DIR": ""}, terminal_cols=140,
        )


def session_only(executable):
    def interact(process, fd, _slave, output, base):
        # Deterministic even as root: a directory cannot be read as config.
        # This fails the save's load-before-write step, not its atomic write.
        path = config_path(base)
        original = path.read_bytes()
        path.unlink()
        path.mkdir()
        try:
            visit_beta(process, fd, output)
            home(process, fd, output, b"this session only")
            frame = h.resize_and_wait(process, fd, output, rows=32, columns=140,
                                      needle=b"this session only", controls=(h.FULL_REDRAW,))
            if b"Continue with beta" not in h.screen_text(frame):
                raise AssertionError("failed config load lost the session target")
        finally:
            path.rmdir()
            path.write_bytes(original)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Home receipt load-before-write failure stays session only",
        interact=interact, prepare_workspace=prepare('opening = "overview"\n'),
        http_fixtures=fixtures(),
        extra_env={"MASC_CONFIG_DIR": ""}, terminal_cols=140,
    )


def changed_disk_mode(executable):
    for initial, changed in (("overview", "last"), ("last", "keeper")):
        text = (f'opening = "{initial}"\nopening_keeper = "alpha"\n'
                'last_chat_keeper = "beta"\n')

        def interact(process, fd, _slave, output, base):
            if initial == "last":
                h.wait_for_output(process, fd, output,
                                  "Keepers ▸ beta ▸ chat".encode(), start=0, timeout=10)
                h.send_and_wait(process, fd, output, b"\x1b", b":settings")
            home(process, fd, output, b"Continue with beta")
            path = config_path(base)
            # Another config writer changes the preference after startup.
            path.write_text(path.read_text().replace(
                f'opening = "{initial}"', f'opening = "{changed}"'
            ), encoding="utf-8")
            # Same receipt target: explicit re-entry still must inspect disk.
            visit_beta(process, fd, output)
            stored = settings(base)
            expected = "beta" if changed == "last" else "alpha"
            if (stored["opening"], stored["opening_keeper"], stored["last_chat_keeper"]) != (
                changed, expected, "beta"
            ):
                raise AssertionError(f"visit ignored current locked startup mode: {stored}")
            home(process, fd, output, b"Continue with beta")
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable, description=f"Home visit after disk mode {initial} to {changed}",
            interact=interact, prepare_workspace=prepare(text),
            http_fixtures=fixtures(),
            extra_env={"MASC_CONFIG_DIR": ""}, starts_in_chat=initial == "last",
            terminal_cols=140,
        )


def roster_failure_and_deletion(executable):
    requests = []

    def interact(process, fd, _slave, output, base):
        home(process, fd, output, b"Continue with beta")
        metadata = Path(base) / ".masc" / "keepers" / "beta.json"
        original = metadata.read_bytes()
        metadata.write_text("{broken metadata", encoding="utf-8")
        try:
            start = len(output)
            os.write(fd, b"r")
            h.wait_for_output(process, fd, output, b"roster unavailable; read history",
                              start=start, timeout=10)
            home(process, fd, output, b"Last conversation with beta")
            # Choose is last and named history is immediately before it;
            # saturate downward without assuming how many decisions exist.
            os.write(fd, b"jjjjjjk")
            h.drain_until_quiet(process, fd, output)
            h.send_and_wait(process, fd, output, b"\r",
                            "Keepers ▸ beta ▸ chat".encode())
            before = len(requests)
            h.send_and_wait(process, fd, output, b"receipt-readonly-probe\r",
                            b"Cannot send while the Keeper roster is unavailable")
            h.drain_until_quiet(process, fd, output)
            # The harness records POST and DELETE, never GET. Ignore unrelated
            # background traffic, but reject even an empty chat mutation.
            if any(path.startswith("/api/v1/keepers/beta/chat")
                   for path, _body in requests[before:]):
                raise AssertionError("read-only history sent a chat mutation")
            # A complete deletion keeps already-open history readable; Home
            # offers selection rather than resuming the deleted recipient.
            # Return while metadata is still broken, retaining the named
            # read-only history. Delete only after that frame so r requests an
            # actual transition instead of asking an unchanged frame to redraw.
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            h.read_available(fd, output)
            before_deletion = h.screen_text(bytes(output))
            assert b"roster unavailable; read history" in before_deletion, before_deletion
            metadata.unlink()
            # A refresh can emit only changed rows. Require its completed frame
            # and inspect the composed screen instead of a duplicate label.
            start = len(output)
            os.write(fd, b"r")
            h.wait_for_terminal_input_consumed(_slave)

            def refreshed_receipt_is_unavailable():
                end = output.rfind(h.FRAME_END)
                if end < start:
                    return False
                current = h.screen_text(bytes(output[:end + len(h.FRAME_END)]))
                return (b"conversation beta unavailable" in current
                        and b"Continue with beta" not in current
                        and b"roster unavailable; read history" not in current)

            if not h.wait_for_fixture_state(process, fd, output,
                    refreshed_receipt_is_unavailable, timeout=3.0):
                raise AssertionError(f"fresh completed Home receipt did not reflect deletion: {bytes(output)!r}")
            end = output.rfind(h.FRAME_END)
            current = h.screen_text(bytes(output[:end + len(h.FRAME_END)]))
            assert b"conversation beta unavailable" in current, current
            assert b"Continue with beta" not in current, current
            assert b"roster unavailable; read history" not in current, current
        finally:
            metadata.write_bytes(original)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Home named history survives failed roster until complete deletion",
        interact=interact,
        prepare_workspace=prepare('opening = "overview"\nlast_chat_keeper = "beta"\n'),
        http_fixtures=fixtures(), http_requests=requests,
        extra_env={"MASC_CONFIG_DIR": ""}, terminal_cols=140, refresh=0.2,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    if sys.platform == "linux":
        for mode in ("overview", "keeper", "last"):
            persistence(executable, mode)
    else:
        print("Home receipt restart: SKIP (Linux restart fixture only)")
    unavailable_receipts(executable)
    session_only(executable)
    changed_disk_mode(executable)
    roster_failure_and_deletion(executable)
    print("Home receipt PTY: PASS")
