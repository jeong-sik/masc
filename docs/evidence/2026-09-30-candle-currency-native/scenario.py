"""Observe currency and lifecycle controls through the real TUI in a PTY.

The loopback server supplies synthetic canonical wire observations. Native
ledger tests own their production; this suite proves decoding, display and
failure isolation in the running TUI, without touching a live workspace.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import sys
import threading
from pathlib import Path

import test_tui_keyboard_input as h


SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_candle.ml",
    "bin/masc_tui_keeper_control.ml",
    "lib/tui_decode.ml",
    "lib/candle/candle_observation.ml",
)

ROSTER_PATH = "/api/v1/gate/keepers?detailed=true"
DIRECTIVE_PATH = "/api/v1/keepers/alpha/directive"
INFO_TAB = "▸Info".encode()
READY = {
    "status": "ready",
    "issued_milli": "18446744073709551614999",
    "burned_milli": "9007199254740993",
    "circulating_milli": "18446735066510296874006",
}
SUMMARY = (
    b"Candle issued: 18446744073709551614.999",
    b"Candle burned: 9007199254740.993",
    b"Candle circulating: 18446735066510296874.006",
)
BALANCE_MILLI = "9007199254740993"
BALANCE = b"9007199254740.993 Candle"
WAIT_SECONDS = 10.0  # A test failure deadline, not a product refresh policy.


def screen(output: bytearray) -> bytes:
    end = output.rfind(h.FRAME_END)
    return h.screen_text(bytes(output[:end + len(h.FRAME_END)])) if end >= 0 else b""


def await_screen(process, fd, output, predicate, description):
    if not h.wait_for_fixture_state(process, fd, output,
            lambda: predicate(screen(output)), timeout=WAIT_SECONDS):
        raise AssertionError(f"{description}: {screen(output)!r}")


def balance_contains(text: bytes, value: bytes) -> bool:
    return any(b"Candle balance:" in line and value in line for line in text.splitlines())


class CurrencyRoster:
    def __init__(self, original):
        self.original = original
        self.lock = threading.Lock()
        self.calls = []
        self.publish("ready")

    def publish(self, phase):
        payload = copy.deepcopy(self.original)
        payload["candle"] = dict(READY)
        for row in payload["keepers"]:
            row["candle_balance_milli"] = BALANCE_MILLI if row["name"] == "alpha" else "0"
        if phase == "disabled":
            payload["candle"] = {"status": "disabled", "reason": "ledger deliberately unavailable"}
            for row in payload["keepers"]:
                row["candle_balance_milli"] = None
        elif phase == "malformed-supply":
            payload["candle"]["issued_milli"] = int(READY["issued_milli"])
        elif phase == "malformed-balance":
            payload["keepers"][0]["candle_balance_milli"] = 123.0
        elif phase == "off":
            payload["candle"] = {"status": "off"}
            for row in payload["keepers"]:
                row["candle_balance_milli"] = None
        elif phase != "ready":
            raise AssertionError(f"unknown fixture phase {phase}")
        with self.lock:
            self.phase, self.payload = phase, payload

    def __call__(self):
        with self.lock:
            self.calls.append(self.phase)
            return 200, self.payload


def run(binary: str, phase: str, captures: Path | None):
    fixtures = h.keeper_runtime_http_fixtures()
    roster = CurrencyRoster(fixtures[ROSTER_PATH][1])
    fixtures[ROSTER_PATH] = roster
    fixtures[DIRECTIVE_PATH] = (200, {"ok": True})
    requests: h.HttpRequests = []

    def capture(output, name):
        visible = screen(output)
        if captures is not None:
            (captures / f"{phase}-{name}.txt").write_bytes(visible)
            (captures / f"{phase}-{name}.pty").write_bytes(output)
        print(f"TUI_CAPTURE candle-currency {phase} {name}\n" + visible.decode(errors="replace"), flush=True)

    def interact(process, fd, _slave, output, _base):
        try:
            await_screen(process, fd, output,
                lambda text: all(line in text for line in SUMMARY), "exact large currency summary")
            capture(output, "ready-overview")
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", INFO_TAB)
            await_screen(process, fd, output, lambda text: balance_contains(text, BALANCE),
                         "exact Keeper balance")
            capture(output, "ready-info")

            # Escape returns through the roster to the initial surface. Its
            # title changes from Overview to Dashboard in the main stack;
            # the currency reading, not a numeric tab, identifies it here.
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            h.send_and_wait(process, fd, output, b"\x1b", SUMMARY[0])
            roster.publish(phase)
            os.write(fd, b"r")
            status = b"Candle disabled:" if phase == "disabled" else b"Candle unavailable:"
            await_screen(process, fd, output,
                lambda text: (b"Candle " not in text if phase == "off" else status in text)
                and not any(line in text for line in SUMMARY), "withdraw old summary after " + phase)
            capture(output, "changed-overview")

            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", INFO_TAB)
            balance_status = b"disabled:" if phase == "disabled" else b"unavailable:"
            await_screen(process, fd, output,
                lambda text: b"Name:" in text and b"alpha" in text and b"Paused:" in text
                and BALANCE not in text
                and (b"Candle balance:" not in text if phase == "off"
                     else balance_contains(text, balance_status)),
                "retain Keeper identity and truthful balance after " + phase)
            capture(output, "changed-info")

            if phase != "off":
                # A malformed currency reading must not invalidate the
                # independent live Keeper row and withdraw its controls.
                h.send_and_wait(process, fd, output, b"p", b"alpha pause accepted")
                assert h.wait_for_fixture_state(process, fd, output,
                    lambda: any(path == DIRECTIVE_PATH for path, _ in requests), timeout=WAIT_SECONDS)
                directives = [json.loads(body) for path, body in requests if path == DIRECTIVE_PATH]
                assert directives == [{"action": "pause"}], directives
                capture(output, "control-accepted")
                roster.publish("ready")
                os.write(fd, b"r")
                await_screen(process, fd, output,
                    lambda text: balance_contains(text, BALANCE),
                    "currency reading recovers without reopening the Keeper")
                capture(output, "recovered-info")
            os.write(fd, b"q")
        finally:
            if captures is not None:
                (captures / f"{phase}-complete.pty").write_bytes(output)
                (captures / f"{phase}-requests.json").write_text(json.dumps({
                    "roster_phases": roster.calls,
                    "posts": [{"path": path, "body": json.loads(body)} for path, body in requests],
                }, indent=2) + "\n")

    h.run_terminal_scenario(binary, description="Candle currency survives " + phase,
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        terminal_rows=38, terminal_cols=120)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    artifact_root = os.environ.get("RUNNER_TEMP")
    captures = Path(artifact_root) / "candle-currency-tui" if artifact_root else None
    if captures is not None:
        captures.mkdir(parents=True, exist_ok=True)
        (captures / "manifest.json").write_text(json.dumps({
            "scope": "synthetic currency wire through a real TUI PTY; not a live workspace",
            "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "supply": READY, "keeper_balance_milli": BALANCE_MILLI,
        }, indent=2) + "\n")
    for phase in ("disabled", "malformed-supply", "malformed-balance", "off"):
        run(binary, phase, captures)
    print("Candle currency TUI: PASS (4 real PTY scenarios)")
