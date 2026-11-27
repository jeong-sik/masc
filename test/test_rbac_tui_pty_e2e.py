#!/usr/bin/env python3
"""Live PTY RBAC E2E smoke suite for masc_tui.exe.

Spawns the real compiled masc_tui.exe binary inside a real macOS/Linux PTY
(140x48) against live single-user and multi-account main_eio.exe servers and
asserts real role badges, Auth_gate modals, and locked admin/player screens.
"""

from __future__ import annotations

import codecs
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
from urllib.parse import urlparse


COLS = 140
ROWS = 48
BOOT_TIMEOUT_SEC = 20.0
STEP_TIMEOUT_SEC = 10.0


class MiniVT100:
    """Minimal VT100 screen buffer so cursor-positioned TUI frames render cleanly."""

    def __init__(self, rows: int = ROWS, cols: int = COLS) -> None:
        self.rows = rows
        self.cols = cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = 0
        self.c = 0
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.state = "normal"
        self.csi_buf = ""

    def _clear_line(self, row: int, start: int = 0, end: int | None = None) -> None:
        if 0 <= row < self.rows:
            hi = self.cols if end is None else min(end, self.cols)
            for col in range(max(0, start), hi):
                self.grid[row][col] = " "

    def _clear_screen(self) -> None:
        for row in range(self.rows):
            self._clear_line(row)

    def _apply_csi(self, final: str, params_raw: str) -> None:
        clean = params_raw.lstrip("?><!")
        parts = [int(p) if p.isdigit() else 0 for p in clean.split(";")] if clean else []

        def p(idx: int, default: int = 1) -> int:
            if idx < len(parts) and parts[idx] > 0:
                return parts[idx]
            return default

        if final in ("H", "f"):
            self.r = max(0, min(self.rows - 1, p(0, 1) - 1))
            self.c = max(0, min(self.cols - 1, p(1, 1) - 1))
        elif final == "A":
            self.r = max(0, self.r - p(0, 1))
        elif final == "B":
            self.r = min(self.rows - 1, self.r + p(0, 1))
        elif final == "C":
            self.c = min(self.cols - 1, self.c + p(0, 1))
        elif final == "D":
            self.c = max(0, self.c - p(0, 1))
        elif final == "G":
            self.c = max(0, min(self.cols - 1, p(0, 1) - 1))
        elif final == "J":
            mode = parts[0] if parts else 0
            if mode in (2, 3):
                self._clear_screen()
            elif mode == 0:
                self._clear_line(self.r, self.c)
                for row in range(self.r + 1, self.rows):
                    self._clear_line(row)
        elif final == "K":
            mode = parts[0] if parts else 0
            if mode == 0:
                self._clear_line(self.r, self.c)
            elif mode == 1:
                self._clear_line(self.r, 0, self.c + 1)
            elif mode == 2:
                self._clear_line(self.r)

    def feed(self, data: bytes) -> None:
        text = self.decoder.decode(data, final=False)
        for ch in text:
            if self.state == "normal":
                if ch == "\x1b":
                    self.state = "esc"
                elif ch == "\r":
                    self.c = 0
                elif ch == "\n":
                    self.r = min(self.rows - 1, self.r + 1)
                elif ch == "\b":
                    self.c = max(0, self.c - 1)
                elif ord(ch) >= 0x20:
                    if 0 <= self.r < self.rows and 0 <= self.c < self.cols:
                        self.grid[self.r][self.c] = ch
                        self.c += 1
            elif self.state == "esc":
                if ch == "[":
                    self.state = "csi"
                    self.csi_buf = ""
                elif ch == "]":
                    self.state = "osc"
                elif ch in ("(", ")", "*", "+"):
                    self.state = "charset"
                else:
                    self.state = "normal"
            elif self.state == "charset":
                self.state = "normal"
            elif self.state == "osc":
                if ch == "\x07":
                    self.state = "normal"
                elif ch == "\x1b":
                    self.state = "osc_esc"
            elif self.state == "osc_esc":
                self.state = "normal"
            elif self.state == "csi":
                if "@" <= ch <= "~":
                    self._apply_csi(ch, self.csi_buf)
                    self.state = "normal"
                else:
                    self.csi_buf += ch

    def text(self) -> str:
        return "\n".join("".join(row).rstrip() for row in self.grid)


def set_winsize(fd: int, rows: int, cols: int) -> None:
    packed = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, packed)


class TuiPtySession:
    def __init__(
        self,
        tui_bin: str,
        base_path: str,
        url: str,
        token: str | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> None:
        parsed = urlparse(url)
        port = parsed.port
        assert port is not None, f"missing port in url {url}"
        self.vt = MiniVT100(ROWS, COLS)
        self.raw_bytes = bytearray()

        master_fd, slave_fd = pty.openpty()
        set_winsize(slave_fd, ROWS, COLS)

        pid = os.fork()
        if pid == 0:
            try:
                os.close(master_fd)
                os.setsid()
                try:
                    fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
                except OSError:
                    pass
                os.dup2(slave_fd, 0)
                os.dup2(slave_fd, 1)
                os.dup2(slave_fd, 2)
                if slave_fd > 2:
                    os.close(slave_fd)

                env = {
                    k: v
                    for k, v in os.environ.items()
                    if not k.startswith("MASC_") and not k.startswith("AGENT_CORE_")
                }
                env["TERM"] = "xterm-256color"
                env["COLORTERM"] = "truecolor"
                env["LANG"] = "en_US.UTF-8"
                env["LC_ALL"] = "en_US.UTF-8"
                if extra_env:
                    env.update(extra_env)
                if token is not None:
                    env["MASC_TOKEN"] = token

                argv = [
                    tui_bin,
                    "--base-path",
                    base_path,
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--lang",
                    "en",
                    "--no-auto-start",
                ]
                os.execve(tui_bin, argv, env)
            except BaseException:
                os._exit(127)

        os.close(slave_fd)
        self.pid = pid
        self.fd = master_fd
        self.closed = False

    def _drain(self, timeout: float = 0.1) -> bool:
        got = False
        while select.select([self.fd], [], [], timeout)[0]:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.raw_bytes.extend(chunk)
            self.vt.feed(chunk)
            got = True
            timeout = 0.02
        return got

    def wait_for_any(self, needles: list[str], timeout: float = BOOT_TIMEOUT_SEC) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self._drain(0.1)
            screen = self.vt.text()
            for needle in needles:
                if needle in screen:
                    return screen
            waited, status = os.waitpid(self.pid, os.WNOHANG)
            if waited == self.pid:
                raise AssertionError(
                    f"masc_tui exited early (status={status}) waiting for {needles}.\n"
                    f"--- SCREEN ---\n{screen}\n--- RAW TAIL ---\n"
                    f"{self.raw_bytes[-1200:].decode('utf-8', errors='replace')}"
                )
        screen = self.vt.text()
        raise AssertionError(
            f"Timed out after {timeout}s waiting for any of {needles}.\n"
            f"--- SCREEN ---\n{screen}"
        )

    def wait_for_absent(self, needle: str, timeout: float = STEP_TIMEOUT_SEC) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self._drain(0.1)
            screen = self.vt.text()
            if needle not in screen:
                return screen
            waited, status = os.waitpid(self.pid, os.WNOHANG)
            if waited == self.pid:
                raise AssertionError(
                    f"masc_tui exited early (status={status}) waiting for {needle!r} to clear.\n"
                    f"--- SCREEN ---\n{screen}"
                )
        screen = self.vt.text()
        raise AssertionError(
            f"Timed out after {timeout}s waiting for {needle!r} to disappear.\n"
            f"--- SCREEN ---\n{screen}"
        )

    def send(self, data: bytes) -> None:
        os.write(self.fd, data)

    def close_cleanly(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            os.write(self.fd, b"\x11")  # Ctrl+Q graceful exit
        except OSError:
            pass
        deadline = time.monotonic() + 5.0
        exited = False
        while time.monotonic() < deadline:
            self._drain(0.05)
            waited, _ = os.waitpid(self.pid, os.WNOHANG)
            if waited == self.pid:
                exited = True
                break
        if not exited:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.kill(self.pid, sig)
                except ProcessLookupError:
                    break
                end = time.monotonic() + 2.0
                while time.monotonic() < end:
                    waited, _ = os.waitpid(self.pid, os.WNOHANG)
                    if waited == self.pid:
                        exited = True
                        break
                    time.sleep(0.05)
                if exited:
                    break
        try:
            os.close(self.fd)
        except OSError:
            pass


def assert_not_present(screen: str, forbidden: list[str], label: str) -> None:
    for bad in forbidden:
        if bad in screen:
            raise AssertionError(f"{label}: unexpected text {bad!r} rendered.\n--- SCREEN ---\n{screen}")


def run_case(name: str, fn) -> None:
    fn()
    print(f"[tui-pty-e2e] PASS {name}", flush=True)


def main() -> int:
    tui_bin = os.environ["RBAC_TUI_BIN"]
    manifest_path = os.environ["RBAC_E2E_MANIFEST"]
    su_off_url = os.environ["RBAC_SU_OFF_URL"]
    su_auth_url = os.environ["RBAC_SU_AUTH_URL"]
    su_strict_url = os.environ["RBAC_SU_STRICT_URL"]
    ma_url = os.environ["RBAC_MA_URL"]

    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    su_off_base = manifest["su_off"]["base_path"]
    su_tokens = manifest["su_auth"]["tokens"]
    su_strict_tokens = manifest["su_strict"]["tokens"]
    ma_pats = manifest["ma"]["pats"]
    ma_svc = manifest["ma"]["service_token"]
    iso_home = os.path.join(manifest["root"], "tui_home")
    # Use a client-side base-path with no server .masc/auth/*.token files so
    # every TUI case proves authentic over-the-wire token/gate behavior.
    client_base = os.path.join(manifest["root"], "tui_client_ws")
    os.makedirs(iso_home, exist_ok=True)
    os.makedirs(client_base, exist_ok=True)
    iso_env = {"HOME": iso_home, "XDG_CONFIG_HOME": os.path.join(iso_home, "xdg")}
    su_auth_base = client_base
    ma_base = client_base

    print("\n=== Phase 3: Live TUI PTY RBAC E2E ===", flush=True)

    # 1. Single-user auth_off
    def case_su_off() -> None:
        s = TuiPtySession(tui_bin, su_off_base, su_off_url, token=None, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["LOCAL ADMIN", "NO-TOK"])
            assert "LOCAL ADMIN" in screen, f"su_off missing LOCAL ADMIN badge:\n{screen}"
            assert_not_present(screen, ["Single-user Authentication Required"], "su_off")
            # Pressing ',' opens Settings overlay -> locked because token auth is disabled.
            s.send(b",")
            locked = s.wait_for_any(
                ["Requires workspace token auth enabled", "token auth"], timeout=STEP_TIMEOUT_SEC
            )
            assert "token auth" in locked.lower(), f"su_off settings should note token auth requirement:\n{locked}"
        finally:
            s.close_cleanly()

    # 2. Single-user Admin token
    def case_su_admin() -> None:
        s = TuiPtySession(tui_bin, su_auth_base, su_auth_url, token=su_tokens["admin"], extra_env=iso_env)
        try:
            screen = s.wait_for_any(["LOCAL ADMIN"])
            assert "NO-TOK" not in screen, f"su_admin should not show NO-TOK:\n{screen}"
            assert_not_present(screen, ["Single-user Authentication Required", su_tokens["admin"]], "su_admin")
            s.send(b",")
            settings = s.wait_for_any(["Settings · Configuration"], timeout=STEP_TIMEOUT_SEC)
            assert_not_present(settings, ["Admin role is required", "Requires workspace token auth enabled"], "su_admin settings")
        finally:
            s.close_cleanly()

    # 3. Single-user Worker token
    def case_su_worker() -> None:
        s = TuiPtySession(tui_bin, su_auth_base, su_auth_url, token=su_tokens["worker"], extra_env=iso_env)
        try:
            screen = s.wait_for_any(["LOCAL WORKER"])
            assert_not_present(screen, ["Single-user Authentication Required", su_tokens["worker"]], "su_worker")
            s.send(b",")
            locked = s.wait_for_any(["Admin role is required"], timeout=STEP_TIMEOUT_SEC)
            assert "Admin role is required" in locked
        finally:
            s.close_cleanly()

    # 4. Single-user Player token
    def case_su_player() -> None:
        s = TuiPtySession(tui_bin, su_auth_base, su_auth_url, token=su_tokens["player"], extra_env=iso_env)
        try:
            screen = s.wait_for_any(["LOCAL PLAYER", "Player role cannot access"])
            assert "LOCAL PLAYER" in screen or "Player role cannot access" in screen
            assert_not_present(screen, [su_tokens["player"]], "su_player")
            if "Player role cannot access" not in screen:
                s.wait_for_any(["Player role cannot access"], timeout=STEP_TIMEOUT_SEC)
        finally:
            s.close_cleanly()

    # 5. Single-user missing token on strict loopback -> Auth_gate
    def case_su_missing_token() -> None:
        s = TuiPtySession(tui_bin, su_auth_base, su_strict_url, token=None, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["Single-user Authentication Required"])
            assert "Token required" in screen or "Bearer token required" in screen, (
                f"missing token gate detail unexpected:\n{screen}"
            )
        finally:
            s.close_cleanly()

    # 6. Single-user bad token on strict loopback -> Auth_gate
    def case_su_bad_token() -> None:
        bad_tok = "invalid-tui-token-smoke-9999"
        s = TuiPtySession(tui_bin, su_auth_base, su_strict_url, token=bad_tok, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["Single-user Authentication Required"])
            assert_not_present(screen, [bad_tok], "su_bad_token must not leak token")
            low = screen.lower()
            assert "rejected" in low or "401" in low or "invalid" in low, (
                f"su_bad_token gate missing rejection detail:\n{screen}"
            )
        finally:
            s.close_cleanly()

    # 6b. Single-user Player token on strict loopback -> Auth_gate (403 on /shell)
    def case_su_strict_player() -> None:
        tok = su_strict_tokens["player"]
        s = TuiPtySession(tui_bin, su_auth_base, su_strict_url, token=tok, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["Single-user Authentication Required"])
            assert_not_present(screen, [tok], "su_strict_player must not leak token")
        finally:
            s.close_cleanly()

    # 7. Multi-account signed_out -> Auth_gate
    def case_ma_signed_out() -> None:
        s = TuiPtySession(tui_bin, ma_base, ma_url, token=None, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["Multi-account Sign-in Required"])
            assert "PAT" in screen, f"ma_signed_out gate should mention PAT remediation:\n{screen}"
        finally:
            s.close_cleanly()

    # 8. Multi-account Worker PAT -> MA WORKER·PAT badge + locked Infra & Settings
    def case_ma_worker_pat() -> None:
        pat = ma_pats["worker_provider"]
        s = TuiPtySession(tui_bin, ma_base, ma_url, token=pat, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["MA WORKER"])
            assert "PAT" in screen, f"ma_worker_pat badge missing PAT:\n{screen}"
            assert_not_present(screen, ["Multi-account Sign-in Required", pat], "ma_worker_pat")
            # Attempt Settings (,) on Pulse -> RBAC gate refuses without mounting Settings overlay.
            s.send(b",")
            locked_set = s.wait_for_any(["Admin role is required"], timeout=STEP_TIMEOUT_SEC)
            assert "Admin role is required" in locked_set
            assert_not_present(locked_set, ["Settings · Configuration"], "ma_worker_pat_settings_blocked")
            # Switch to Infra (6) -> locked workspace screen for MA Worker.
            s.send(b"6")
            locked_infra = s.wait_for_any(["Sandboxes"], timeout=STEP_TIMEOUT_SEC)
            assert "LOCKED" in locked_infra and "Admin role is required" in locked_infra
        finally:
            s.close_cleanly()

    # 9. Multi-account Admin PAT -> MA ADMIN·PAT badge + CANNOT admin (Pat_cannot_admin)
    def case_ma_admin_pat() -> None:
        pat = ma_pats["admin1"]
        s = TuiPtySession(tui_bin, ma_base, ma_url, token=pat, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["MA ADMIN"])
            assert "PAT" in screen, f"ma_admin_pat badge missing PAT:\n{screen}"
            assert_not_present(screen, [pat], "ma_admin_pat")
            s.send(b",")
            locked = s.wait_for_any(
                ["Multi-account PATs cannot hold admin permissions", "PAT credentials cannot perform admin actions"],
                timeout=STEP_TIMEOUT_SEC,
            )
            assert "PAT" in locked
        finally:
            s.close_cleanly()

    # 10. Multi-account Service credential -> MA WORKER·SVC badge + locked Infra
    def case_ma_service() -> None:
        s = TuiPtySession(tui_bin, ma_base, ma_url, token=ma_svc, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["SVC"])
            assert_not_present(screen, ["Multi-account Sign-in Required", ma_svc], "ma_service")
            s.send(b"6")
            locked = s.wait_for_any(["Admin role is required"], timeout=STEP_TIMEOUT_SEC)
            assert "Admin role is required" in locked
        finally:
            s.close_cleanly()

    # 11. Single-user Auth_gate live token entry (masked input -> unlocks without restart)
    def case_su_auth_gate_live_token_entry() -> None:
        admin_tok = su_strict_tokens["admin"]
        worker_tok = su_strict_tokens["worker"]
        s = TuiPtySession(tui_bin, su_auth_base, su_strict_url, token=None, extra_env=iso_env)
        try:
            s.wait_for_any(["Single-user Authentication Required"])
            # Enter Admin token directly inside Auth_gate via [t] -> masked input -> [Enter].
            s.send(b"t")
            editor = s.wait_for_any(["Bearer / PAT (masked):"], timeout=STEP_TIMEOUT_SEC)
            assert "Bearer / PAT (masked):" in editor
            s.send(admin_tok.encode("ascii"))
            # Wait for masked bullet echo and verify raw secret never renders in plaintext.
            masked_screen = s.wait_for_any(["•"], timeout=STEP_TIMEOUT_SEC)
            assert_not_present(masked_screen, [admin_tok], "su_auth_gate_masked_editor")
            s.send(b"\r")
            unlocked = s.wait_for_any(["LOCAL ADMIN"], timeout=BOOT_TIMEOUT_SEC)
            assert_not_present(unlocked, [admin_tok, "Single-user Authentication Required"], "su_auth_gate_unlocked")

            # Open Account & Session overlay via Alt+A, swap to Worker token, verify immediate demotion.
            s.send(b"\x1ba")
            acct = s.wait_for_any(["Multi-Account Own Providers"], timeout=STEP_TIMEOUT_SEC)
            assert "Account & Session" in acct and "Single_user" in acct
            assert "runtime override (masked)" in acct
            s.send(b"t")
            s.wait_for_any(["Apply"], timeout=STEP_TIMEOUT_SEC)
            s.send(worker_tok.encode("ascii") + b"\r")
            swapped = s.wait_for_any(["LOCAL WORKER"], timeout=BOOT_TIMEOUT_SEC)
            assert_not_present(swapped, [worker_tok], "su_account_swap_worker")

            # Close Account overlay and confirm Settings (,) is now locked for Worker.
            s.send(b"\x1b")
            s.wait_for_absent("Multi-Account Own Providers", timeout=STEP_TIMEOUT_SEC)
            s.send(b",")
            locked = s.wait_for_any(["Admin role is required"], timeout=STEP_TIMEOUT_SEC)
            assert "Admin role is required" in locked

            # Reopen Account overlay and press [c] Clear Token -> returns to Auth_gate immediately.
            s.send(b"\x1ba")
            s.wait_for_any(["Multi-Account Own Providers"], timeout=STEP_TIMEOUT_SEC)
            s.send(b"c")
            cleared = s.wait_for_any(["Single-user Authentication Required"], timeout=BOOT_TIMEOUT_SEC)
            assert "Single-user Authentication Required" in cleared
        finally:
            s.close_cleanly()

    # 12. Multi-account Auth_gate PAT entry -> MA WORKER·PAT -> /account own-provider view
    def case_ma_account_overlay_pat_and_providers() -> None:
        pat = ma_pats["worker_provider"]
        worker_pa = manifest["ma"]["worker_provider_account_id"]
        s = TuiPtySession(tui_bin, ma_base, ma_url, token=None, extra_env=iso_env)
        try:
            s.wait_for_any(["Multi-account Sign-in Required"])
            s.send(b"t")
            s.wait_for_any(["Bearer / PAT (masked):"], timeout=STEP_TIMEOUT_SEC)
            s.send(pat.encode("ascii"))
            masked_screen = s.wait_for_any(["•"], timeout=STEP_TIMEOUT_SEC)
            assert_not_present(masked_screen, [pat], "ma_auth_gate_masked_editor")
            s.send(b"\r")
            unlocked = s.wait_for_any(["MA WORKER"], timeout=BOOT_TIMEOUT_SEC)
            assert "PAT" in unlocked
            assert_not_present(unlocked, [pat, "Multi-account Sign-in Required"], "ma_pat_unlocked")

            # Open Account & Session via Alt+A and verify both integrations and personal provider accounts load.
            s.send(b"\x1ba")
            acct = s.wait_for_any(["Multi-Account Own Providers"], timeout=STEP_TIMEOUT_SEC)
            assert "Account & Session" in acct
            assert "Multi_account" in acct
            loaded = s.wait_for_any([worker_pa], timeout=STEP_TIMEOUT_SEC)
            assert worker_pa in loaded and "ollama_cloud" in loaded, (
                f"ma_account_overlay missing provider account {worker_pa!r} or ollama_cloud:\n{loaded}"
            )
            assert_not_present(loaded, [pat], "ma_account_overlay_no_pat_leak")
        finally:
            s.close_cleanly()

    # 13. Multi-account read-only PAT (no manage_own_provider) -> explicit HTTP 403 banner without dropping session
    def case_ma_readonly_pat_403_banner() -> None:
        pat = ma_pats["worker_readonly"]
        s = TuiPtySession(tui_bin, ma_base, ma_url, token=pat, extra_env=iso_env)
        try:
            screen = s.wait_for_any(["MA WORKER"])
            assert "PAT" in screen
            assert_not_present(screen, [pat], "ma_readonly_pat_boot")
            s.send(b"\x1ba")
            acct = s.wait_for_any(["HTTP 403"], timeout=STEP_TIMEOUT_SEC)
            assert "Account & Session" in acct
            assert "manage_own_provider" in acct
            assert_not_present(acct, ["Multi-account Sign-in Required", pat], "ma_readonly_pat_keeps_session")
        finally:
            s.close_cleanly()

    run_case("tui.su_off", case_su_off)
    run_case("tui.su_admin", case_su_admin)
    run_case("tui.su_worker", case_su_worker)
    run_case("tui.su_player", case_su_player)
    run_case("tui.su_missing_token_gate", case_su_missing_token)
    run_case("tui.su_bad_token_gate", case_su_bad_token)
    run_case("tui.su_strict_player_gate", case_su_strict_player)
    run_case("tui.ma_signed_out_gate", case_ma_signed_out)
    run_case("tui.ma_worker_pat", case_ma_worker_pat)
    run_case("tui.ma_admin_pat_no_elevation", case_ma_admin_pat)
    run_case("tui.ma_service_cred", case_ma_service)
    run_case("tui.su_auth_gate_live_token_entry_and_swap", case_su_auth_gate_live_token_entry)
    run_case("tui.ma_account_overlay_pat_and_providers", case_ma_account_overlay_pat_and_providers)
    run_case("tui.ma_readonly_pat_403_banner", case_ma_readonly_pat_403_banner)

    print("[tui-pty-e2e] ALL 14 LIVE PTY CASES PASSED", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
