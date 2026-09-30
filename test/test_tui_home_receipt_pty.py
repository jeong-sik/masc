"""Home conversation receipts, including a real same-workspace Linux restart."""

import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
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
    return h.palette_go(process, fd, output, b"go dashboard", needle)


def visit_beta(process, fd, output):
    h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"beta")
    h.send_and_wait(process, fd, output, b"m", "Keepers ▸ beta ▸ chat".encode())
    h.send_and_wait(process, fd, output, b"\x1b", b":settings")


def restart(process, fd, slave, output, check):
    """Leave the launcher's stop notification pending for the outer harness."""
    if sys.platform != "linux":
        raise AssertionError("same-workspace restart requires Linux waitid WNOWAIT")
    argv = process.args[4:]
    def argument(name):
        return argv[argv.index(name) + 1]

    # Mirror run_terminal_scenario's controlled environment. All identity and
    # endpoint arguments come from the original real-binary argv.
    environment = os.environ.copy()
    for name in ("LINES", "COLUMNS", "NO_COLOR", "MASC_TUI_FORCE_COLOR", "TMUX"):
        environment.pop(name, None)
    environment["PATH"] = h.path_without_masc(environment.get("PATH", ""))
    environment.update(
        MASC_CONFIG_DIR="",
        MASC_BASE_PATH=argument("--base-path"),
        MASC_HOST="127.0.0.1",
        MASC_TUI_SYNC="off",
        TERM="xterm-256color",
        MASC_TOKEN="masc-tui-keyboard-regression-token",
    )
    # --workspace, --port and --refresh remain exactly those of the live
    # fixture server in argv; the harness does not export them as env vars.
    start = len(output)
    os.write(fd, b"qq")
    deadline = time.monotonic() + 5
    while True:
        h.read_available(fd, output)
        status = os.waitid(
            os.P_PID, process.pid, os.WSTOPPED | os.WNOHANG | os.WNOWAIT
        )
        if status is not None:
            if status.si_code != os.CLD_STOPPED or status.si_status != signal.SIGSTOP:
                raise AssertionError(f"unexpected launcher stop: {status!r}")
            break
        if time.monotonic() >= deadline:
            raise AssertionError("first TUI did not leave its launcher stopped")
        select.select([fd], [], [], 0.05)
    if b"Goodbye!" not in output[start:]:
        raise AssertionError("first TUI did not finish before restart")
    # No setsid/TIOCSCTTY: the original launcher still owns this slave.
    child = subprocess.Popen(
        argv, stdin=slave, stdout=slave, stderr=slave,
        env=environment, close_fds=True,
    )
    restarted = h.PtyOutput()
    restarted.pid = child.pid
    try:
        check(child, fd, restarted)
        home(child, fd, restarted, b"MASC Dashboard")
        end = len(restarted)
        os.write(fd, b"qq")
        h.wait_for_output(child, fd, restarted, b"Goodbye!", start=end, timeout=5)
        if child.wait(timeout=2) != 0:
            raise AssertionError("restarted TUI exited unsuccessfully")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=2)
    # Do not SIGCONT or waitpid the original shell. run_terminal_scenario
    # consumes the preserved stop, checks termios, and resumes it itself.


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
            home(child, child_fd, child_output, b"Continue with beta")
            if config_path(base).read_bytes() != committed:
                raise AssertionError("restart overwrote explicit beta receipt")

        restart(process, fd, slave, output, check)

    h.run_terminal_scenario(
        executable, description=f"Home receipt same workspace restart {mode}",
        interact=interact, prepare_workspace=prepare(initial),
        http_fixtures=fixtures(), confirm_exit=b"",
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
                raise AssertionError("failed write lost the session target")
        finally:
            path.rmdir()
            path.write_bytes(original)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Home failed receipt write stays session only",
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
            # A complete observation of deletion now must dismiss named chat.
            metadata.unlink()
            start = len(output)
            os.write(fd, h.FULL_REDRAW)
            h.wait_for_output(process, fd, output, b"MASC Keepers", start=start, timeout=10)
            home(process, fd, output, b"Last conversation beta unavailable")
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
    for mode in ("overview", "keeper", "last"):
        persistence(executable, mode)
    unavailable_receipts(executable)
    session_only(executable)
    changed_disk_mode(executable)
    roster_failure_and_deletion(executable)
    print("Home receipt PTY: PASS")
