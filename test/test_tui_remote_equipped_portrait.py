"""Replay real server roster/PNG receipts through a remote-workspace TUI PTY."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import test_tui_keyboard_input as h
from test_tui_emblem_screen_pty import rgba_png


SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_keeper_portrait.ml",
    "bin/masc_tui_portrait_view.ml",
    "bin/masc_tui_render.ml",
    "lib/keeper_portrait/keeper_portrait_equipment.ml",
    "lib/tui_decode.ml",
    "lib/server/server_dashboard_http_keeper_portrait.ml",
    "test/test_keeper_portrait_http.ml",
)

ROSTER_PATH = "/api/v1/gate/keepers?detailed=true"
KITTY_CHUNK = re.compile(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\")
PORTRAIT_ID = b"42"
KITTY_REPLIES = b"\x1b[6;20;10t" + h.GRAPHICS_SUPPORTED_REPLY
INFO_TAB = "▸Info".encode()
WAIT_SECONDS = 10.0  # Test failure deadline, not a product refresh interval.


def portrait_pngs(wire: bytes) -> list[bytes]:
    """Reassemble complete Kitty transfers; an unread trailing chunk waits."""
    complete: list[bytes] = []
    pending: list[bytes] | None = None
    for match in KITTY_CHUNK.finditer(wire):
        fields = dict(field.split(b"=", 1) for field in match[1].split(b",") if b"=" in field)
        if fields.get(b"a") == b"T":
            assert pending is None, "new transfer interrupted a portrait"
            if fields.get(b"i") == PORTRAIT_ID:
                assert fields.get(b"f") == b"100", "portrait transport is not PNG"
                assert b"o" not in fields, "unexpected Kitty transport compression"
                pending = []
        if pending is not None:
            pending.append(match[2])
            if fields.get(b"m", b"0") == b"0":
                complete.append(base64.b64decode(b"".join(pending), validate=True))
                pending = None
    return complete


def wait_for_picture(process, fd, output, *, start: int, expected: bytes) -> bytes:
    wanted = rgba_png(expected)
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        h.read_available(fd, output)
        images = portrait_pngs(bytes(output[start:]))
        for image in images:
            if rgba_png(image) == wanted:
                return image
        if process.poll() is not None:
            raise AssertionError("TUI exited before the expected remote portrait")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            hashes = [hashlib.sha256(image).hexdigest() for image in images]
            raise AssertionError(f"remote portrait pixels did not arrive; observed PNGs: {hashes}")
        select.select([fd], [], [], min(0.1, remaining))


class Roster:
    def __init__(self, before: bytes, equipped: bytes):
        self.snapshots = {"before": before, "equipped": equipped}
        self.phase = "before"
        self.calls: list[str] = []
        self.lock = threading.Lock()

    def __call__(self):
        with self.lock:
            self.calls.append(self.phase)
            body = self.snapshots[self.phase]
        return h.RawHttpResponse(200, body, content_type="application/json")

    def equip(self):
        with self.lock:
            self.phase = "equipped"

    def count(self):
        with self.lock:
            return len(self.calls)


def remote_portrait(binary: str, evidence: Path) -> None:
    manifest = json.loads((evidence / "manifest.json").read_text())
    keeper = manifest["keeper"]
    before = (evidence / "before.png").read_bytes()
    equipped = (evidence / "equipped.png").read_bytes()
    assert manifest["pixel_size"] == 160
    assert rgba_png(before)[:2] == rgba_png(equipped)[:2] == (160, 160)
    assert rgba_png(before) != rgba_png(equipped), "fixture did not change the portrait"
    roster = Roster((evidence / "before-roster.json").read_bytes(),
                    (evidence / "equipped-roster.json").read_bytes())
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[ROSTER_PATH] = roster
    # Raw health answers deliberately bypass both harness identity fillers.
    # No native state exists here; this distinct path identifies the remote
    # server whose recorded wire is being replayed.
    remote_base = str(evidence / "remote-server-workspace")
    for path in ("/health", "/health?full=1"):
        _, health = h.fleet_safety_fixture()
        health["paths"] = {
            "effective_base_path": remote_base,
            "effective_masc_root": str(Path(remote_base) / ".masc"),
        }
        fixtures[path] = h.RawHttpResponse(200, json.dumps(health).encode(),
                                           content_type="application/json")

    def interact(process, fd, _slave, output, local_base):
        try:
            assert Path(local_base).resolve() != Path(remote_base).resolve()
            assert not (Path(local_base) / ".masc/keepers" / f"{keeper}.json").exists()
            h.wait_for_output(process, fd, output, b"[workspace mismatch]", start=0,
                              timeout=WAIT_SECONDS)
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, keeper.encode())
            start = len(output)
            h.send_and_wait(process, fd, output, b"\r", INFO_TAB)
            first = wait_for_picture(process, fd, output, start=start, expected=before)
            (evidence / "tui-before.png").write_bytes(first)

            # The name and body stay fixed. Only the actual server roster
            # receipt switches to the purchased/equipped state.
            start = len(output)
            roster.equip()
            os.write(fd, b"r")
            changed = wait_for_picture(process, fd, output, start=start, expected=equipped)
            (evidence / "tui-equipped.png").write_bytes(changed)
            assert rgba_png(changed) != rgba_png(first)

            # A subsequent successful read must retain the new pixels. Force
            # a full repaint afterwards, since an identical frame emits none.
            calls = roster.count()
            os.write(fd, b"r")
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: roster.count() > calls, timeout=WAIT_SECONDS), "fresh roster request missing"
            start = len(output)
            h.resize_and_wait(process, fd, output, rows=30, columns=99, needle=b"Identity")
            stable = wait_for_picture(process, fd, output, start=start, expected=equipped)
            (evidence / "tui-refreshed.png").write_bytes(stable)
            assert all(rgba_png(image) == rgba_png(equipped)
                       for image in portrait_pngs(bytes(output[start:]))), "refresh restored stale gear"
            proof = {
                "scope": "native purchase/equip HTTP receipts replayed through a remote-identity real TUI PTY",
                "keeper": keeper,
                "local_base": local_base,
                "remote_base": remote_base,
                "tui_binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                "native_build": manifest["build"],
                "roster_requests": roster.calls,
                "pixel_dimensions": [160, 160],
                "before_rgba_sha256": hashlib.sha256(rgba_png(first)[2]).hexdigest(),
                "equipped_rgba_sha256": hashlib.sha256(rgba_png(changed)[2]).hexdigest(),
                "fresh_refresh_matches": rgba_png(stable) == rgba_png(equipped),
            }
            (evidence / "tui-manifest.json").write_text(json.dumps(proof, indent=2) + "\n")
            os.write(fd, b"q")
        finally:
            (evidence / "tui.pty").write_bytes(output)

    h.run_terminal_scenario(binary,
        description="remote Keeper equipment changes actual terminal PNG pixels",
        interact=interact, http_fixtures=fixtures, preload_input=KITTY_REPLIES)


def main() -> None:
    binary, fixture = (str(Path(path).resolve()) for path in sys.argv[1:3])
    with tempfile.TemporaryDirectory(prefix="masc-remote-portrait-") as temporary:
        root = Path(temporary)
        evidence = root / "candle-equipped-portrait"
        evidence.mkdir()
        try:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = str(root)
            # Run only the existing real purchase/equip/router scenario.
            # Its export is reached after all product assertions succeed.
            result = subprocess.run([fixture, "test", "router", "4"],
                env=environment, capture_output=True, timeout=60, check=False)
            (evidence / "native-fixture.log").write_bytes(result.stdout + result.stderr)
            assert result.returncode == 0, (result.stdout + result.stderr).decode(errors="replace")
            remote_portrait(binary, evidence)
        finally:
            artifact_root = os.environ.get("RUNNER_TEMP")
            if artifact_root:
                shutil.copytree(evidence, Path(artifact_root) / "candle-remote-tui-portrait", dirs_exist_ok=True)
    print("remote TUI equipped portrait: PASS (native HTTP receipts + real PTY pixels)")


if __name__ == "__main__":
    main()
