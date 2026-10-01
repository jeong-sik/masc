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

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness
from test_tui_emblem_screen_pty import rgba_png


SOURCE_MODULES = (
    'bin/masc_tui.ml',
    'bin/masc_tui_keeper_portrait.ml',
    'bin/masc_tui_metrics_tail.ml',
    'bin/masc_tui_portrait_view.ml',
    'bin/masc_tui_render.ml',
    'lib/keeper_portrait/keeper_portrait_equipment.ml',
    'lib/tui_decode.ml',
    'lib/server/server_dashboard_http_keeper_portrait.ml',
    'test/test_keeper_portrait_http.ml',
    'test/tui_keyboard_chat.py',
    'test/tui_keyboard_harness.py',
    'test/tui_keyboard_observer.py',
    'test/tui_keyboard_tools.py',
)

ROSTER_PATH = "/api/v1/gate/keepers?detailed=true"
KITTY_CHUNK = re.compile(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\")
PORTRAIT_ID = b"42"
KITTY_REPLIES = b"\x1b[6;20;10t" + _keyboard_chat.GRAPHICS_SUPPORTED_REPLY
INFO_TAB = "▸Info".encode()
WAIT_SECONDS = 10.0  # Test failure deadline, not a product refresh interval.
REFRESH_APPLIED = b"fresh-roster-applied"


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
        _keyboard_harness.read_available(fd, output)
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
        empty = json.loads(equipped)
        empty.update(keepers=[], count=0, total=0, truncated=False)
        missing_identity = json.loads(equipped)
        del missing_identity["keepers"][0]["meta"]["trace_id"]
        invalid = json.loads(equipped)
        invalid["keepers"][0]["effective_meta_error"] = {
            "keeper": invalid["keepers"][0]["name"], "message": "invalid-remote-keeper-metadata"}
        self.snapshots = {
            "before": (200, before), "equipped": (200, equipped),
            "empty": (200, json.dumps(empty).encode()),
            "missing-identity": (200, json.dumps(missing_identity).encode()),
            "invalid": (200, json.dumps(invalid).encode()),
            "failed": (503, b'{"error":"remote roster unavailable"}'),
        }
        self.phase = "before"
        self.calls: list[str] = []
        self.lock = threading.Lock()
        self.refresh_started = threading.Event()
        self.release_refresh = threading.Event()

    def __call__(self):
        with self.lock:
            self.calls.append(self.phase)
            status, body = self.snapshots[self.phase]
            held = self.phase == "refreshed"
        if held:
            self.refresh_started.set()
            if not self.release_refresh.wait(timeout=30):
                raise AssertionError("fresh roster fixture was never released")
        return _keyboard_harness.RawHttpResponse(status, body, content_type="application/json")

    def publish(self, phase):
        with self.lock:
            self.phase = phase

    def count(self):
        with self.lock:
            return len(self.calls)

    def hold_refresh(self, keeper: str) -> bytes:
        # A labelled scenario derivative of the native equipped receipt.
        # Only the decoder's displayed runtime_blocker_summary is marked;
        # equipment, identity and every other native field remain unchanged.
        payload = json.loads(self.snapshots["equipped"][1])
        row = next(row for row in payload["keepers"] if row["name"] == keeper)
        row["runtime_blocker_summary"] = REFRESH_APPLIED.decode()
        body = json.dumps(payload).encode()
        with self.lock:
            self.snapshots["refreshed"] = (200, body)
            self.phase = "refreshed"
        return body


class RemoteIdentity:
    def __init__(self, base: str):
        self.base = base
        self.lock = threading.Lock()

    def publish(self, base: str):
        with self.lock:
            self.base = base

    def __call__(self):
        with self.lock:
            base = self.base
        _, health = _keyboard_harness.fleet_safety_fixture()
        health["paths"] = {"effective_base_path": base,
                           "effective_masc_root": str(Path(base) / ".masc")}
        return _keyboard_harness.RawHttpResponse(200, json.dumps(health).encode(),
                                 content_type="application/json")


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
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[ROSTER_PATH] = roster
    requests: _keyboard_harness.HttpRequests = []
    boot_path = f"/api/v1/keepers/{keeper}/boot"
    held_boot = _keyboard_harness.GatedHttpResponse((409, {"error": "paused owner"}), hold_seconds=30.0)
    boot_armed = threading.Event()
    fixtures[boot_path] = lambda: held_boot() if boot_armed.is_set() else (200, {"ok": True})
    directive_path = f"/api/v1/keepers/{keeper}/directive"
    fixtures[directive_path] = (200, {"ok": True})
    # Raw health answers deliberately bypass both harness identity fillers.
    # No native state exists here; this distinct path identifies the remote
    # server whose recorded wire is being replayed.
    remote_base = str(evidence / "remote-server-workspace")
    remote_identity = RemoteIdentity(remote_base)
    for path in ("/health", "/health?full=1"):
        _, health = _keyboard_harness.fleet_safety_fixture()
        health["paths"] = {
            "effective_base_path": remote_base,
            "effective_masc_root": str(Path(remote_base) / ".masc"),
        }
        fixtures[path] = remote_identity
        receipt = "health.json" if path == "/health" else "full-health.json"
        (evidence / receipt).write_text(json.dumps(health, indent=2) + "\n")

    def interact(process, fd, _slave, output, local_base):
        def screen_is(predicate, label):
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: predicate(_keyboard_harness.screen_text(bytes(output))), timeout=WAIT_SECONDS), label

        try:
            assert Path(local_base).resolve() != Path(remote_base).resolve()
            assert not (Path(local_base) / ".masc/keepers" / f"{keeper}.json").exists()
            # The title's badge can be clipped after a long workspace name.
            # The footer reserves its conflict notice; require the running
            # TUI's typed mismatch and its canonical local workspace there.
            mismatch = b"MISMATCH local " + str(Path(local_base).resolve()).encode()
            _keyboard_harness.wait_for_output(process, fd, output, mismatch, start=0,
                              timeout=WAIT_SECONDS)
            mismatch_footer = next(line for line in _keyboard_harness.screen_text(bytes(output)).splitlines()
                                   if mismatch in line).decode(errors="replace")
            _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
            _keyboard_harness.select_keeper_row(process, fd, output, keeper.encode())
            start = len(output)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", INFO_TAB)
            first = wait_for_picture(process, fd, output, start=start, expected=before)
            (evidence / "tui-before.png").write_bytes(first)

            # The name and body stay fixed. Only the actual server roster
            # receipt switches to the purchased/equipped state.
            start = len(output)
            roster.publish("equipped")
            os.write(fd, b"r")
            changed = wait_for_picture(process, fd, output, start=start, expected=equipped)
            (evidence / "tui-equipped.png").write_bytes(changed)
            assert rgba_png(changed) != rgba_png(first)

            # A subsequent successful read must retain the new pixels. Force
            # a full repaint afterwards, since an identical frame emits none.
            marked_receipt = roster.hold_refresh(keeper)
            (evidence / "refreshed-roster-fixture.json").write_bytes(marked_receipt)
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output,
                roster.refresh_started, timeout=WAIT_SECONDS), "fresh roster request missing"
            assert REFRESH_APPLIED not in _keyboard_harness.screen_text(bytes(output)), \
                "held fresh roster was applied before release"
            roster.release_refresh.set()

            def fresh_roster_visible():
                end = output.rfind(_keyboard_harness.FRAME_END)
                return end >= 0 and REFRESH_APPLIED in _keyboard_harness.screen_text(
                    bytes(output[:end + len(_keyboard_harness.FRAME_END)]))

            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                fresh_roster_visible, timeout=WAIT_SECONDS), \
                "fresh roster was not applied to the client-visible Current failure field"
            start = len(output)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=99, needle=b"Identity")
            stable = wait_for_picture(process, fd, output, start=start, expected=equipped)
            (evidence / "tui-refreshed.png").write_bytes(stable)
            assert all(rgba_png(image) == rgba_png(equipped)
                       for image in portrait_pngs(bytes(output[start:]))), "refresh restored stale gear"

            # Presentation metadata can fail independently of lifecycle.
            # The same real native row still offers its observed boot action.
            roster.publish("missing-identity")
            calls = roster.count()
            os.write(fd, b"r")
            assert _keyboard_harness.wait_for_fixture_state(process, fd, output,
                lambda: roster.count() > calls, timeout=WAIT_SECONDS)
            _keyboard_harness.resize_and_wait(process, fd, output, rows=70, columns=99, needle=b"Metadata:")
            screen_is(lambda text: b"Metadata:" in text and b"trace_id" in text
                      and b"metrics not read for the remote workspace" in text,
                      "unavailable identity and remote metrics were not visible")
            _keyboard_harness.send_and_wait(process, fd, output, b"p", f"{keeper} boot accepted".encode())
            assert [json.loads(body) for path, body in requests if path == boot_path] == [{}]
            assert not (Path(local_base) / ".masc/keepers" / f"{keeper}.json").exists()

            # A decoder error row has a verified name but no runtime payload.
            # It remains selectable and exposes only its Invalid-state actions.
            roster.publish("invalid")
            os.write(fd, b"r")
            screen_is(lambda text: b"invalid-remote-keeper-metadata" in text,
                      "invalid remote Keeper was dropped from navigation")
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            _keyboard_harness.select_keeper_row(process, fd, output, keeper.encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"x", f"press x again to delete {keeper}".encode())
            assert not any(path == "/api/v1/dashboard/agents/purge" for path, _ in requests)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", INFO_TAB)

            roster.publish("failed")
            os.write(fd, b"r")
            screen_is(lambda text: b"no Keeper selected" in text
                      and b"remote roster unavailable" in text, "failed roster retained selection")
            roster.publish("empty")
            os.write(fd, b"r")
            screen_is(lambda text: b"server Keeper roster is empty" in text
                      and b"not loaded" not in text, "empty remote roster was not observed")
            roster.publish("equipped")
            os.write(fd, b"r")
            _keyboard_harness.select_keeper_row(process, fd, output, keeper.encode())
            start = len(output)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", INFO_TAB)
            recovered = wait_for_picture(process, fd, output, start=start, expected=equipped)
            (evidence / "tui-recovered.png").write_bytes(recovered)
            _keyboard_harness.send_and_wait(process, fd, output, b"c", b"Chat requires a matching workspace")

            # Hold an already-dispatched Boot's paused-owner response across
            # the boundary. The remaining Resume/Boot plan belongs to its
            # original workspace, even though C names the same Keeper.
            # Keep the exact authority path in the footer for this boundary
            # proof; the earlier 99-column portrait pixel checks stay intact.
            _keyboard_harness.resize_and_wait(process, fd, output, rows=70, columns=300, needle=b"Identity")
            boot_armed.set()
            os.write(fd, b"p")
            assert _keyboard_harness.wait_for_fixture_event(process, fd, output, held_boot.requested,
                timeout=WAIT_SECONDS), "the lifecycle response was not held"
            c_payload = json.loads(roster.snapshots["equipped"][1])
            c_payload["keepers"][0]["runtime_blocker_summary"] = "authority-c-current-roster"
            with roster.lock:
                roster.snapshots["c-current"] = (200, json.dumps(c_payload).encode())
            roster.publish("c-current")
            c_base = str(evidence / "another-remote-workspace")
            remote_identity.publish(c_base)
            screen_is(lambda text: b"Base: " + c_base.encode() in text
                      and b"MASC Keepers" in text,
                      "C authority did not withdraw B's detail selection")
            # Row withdrawal returns the old detail to the list. Select C's
            # actual row and reopen Info, where Current failure is rendered.
            _keyboard_harness.select_keeper_row(process, fd, output, keeper.encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", INFO_TAB)
            screen_is(lambda text: b"authority-c-current-roster" in text,
                      "C roster was not applied while B Boot was held")
            lifecycle_offset = len(requests)
            held_boot.release.set()
            c_payload["keepers"][0]["runtime_blocker_summary"] = "authority-c-settled-roster"
            with roster.lock:
                roster.snapshots["c-settled"] = (200, json.dumps(c_payload).encode())
            roster.publish("c-settled")
            screen_is(lambda text: b"authority-c-settled-roster" in text,
                      "fresh C roster after release was not applied")
            assert not [path for path, _ in requests[lifecycle_offset:]
                if path in (boot_path, directive_path)],                 "a superseded B lifecycle plan sent a successor request to C"
            boot_armed.clear()

            # The automatic refresh (no cancelling input) changes authority
            # while Delete is armed. The same name in the new workspace
            # requires a fresh first press, never the old confirmation.
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            armed = f"press x again to delete {keeper}".encode()
            _keyboard_harness.send_and_wait(process, fd, output, b"x", armed)
            remote_identity.publish(str(evidence / "third-remote-workspace"))
            screen_is(lambda text: armed not in text, "delete arm crossed remote workspace identity")
            _keyboard_harness.select_keeper_row(process, fd, output, keeper.encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"x", armed)
            assert not any(path == "/api/v1/dashboard/agents/purge" for path, _ in requests), requests
            proof = {
                "scope": "native purchase/equip HTTP receipts replayed through a remote-identity real TUI PTY",
                "keeper": keeper,
                "local_base": local_base,
                "remote_base": remote_base,
                "workspace_mismatch_footer": mismatch_footer,
                "tui_binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                "native_build": manifest["build"],
                "roster_requests": roster.calls,
                "fresh_roster_application_barrier": {
                    "source": "scenario derivative of native equipped roster receipt",
                    "mutated_field": "runtime_blocker_summary",
                    "display": "Keeper Info Current failure",
                    "marker": REFRESH_APPLIED.decode(),
                },
                "pixel_dimensions": [160, 160],
                "before_rgba_sha256": hashlib.sha256(rgba_png(first)[2]).hexdigest(),
                "equipped_rgba_sha256": hashlib.sha256(rgba_png(changed)[2]).hexdigest(),
                "fresh_refresh_matches": rgba_png(stable) == rgba_png(equipped),
                "failure_empty_recovery_matches": rgba_png(recovered) == rgba_png(equipped),
                "metadata_failure_preserves_lifecycle": True,
                "workspace_switch_withdraws_delete_confirmation": True,
                "posts": [{"path": path, "body": json.loads(body)} for path, body in requests],
            }
            (evidence / "tui-manifest.json").write_text(json.dumps(proof, indent=2) + "\n")
            os.write(fd, b"q")
        finally:
            held_boot.release.set()
            roster.release_refresh.set()
            (evidence / "tui.pty").write_bytes(output)

    _keyboard_harness.run_terminal_scenario(binary,
        description="remote Keeper equipment changes actual terminal PNG pixels",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        refresh=0.5, preload_input=KITTY_REPLIES)


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
