"""Admitted voice saves and deletion retries outlive retired observations."""
import json
import os
from pathlib import Path
import sys
import threading

import tui_keyboard_harness as h
import tui_keyboard_voice as voice


class Identity:
    def __init__(self):
        self.base = ""
        self.ready = True
        self.lock = threading.Lock()

    def prepare(self, base):
        h.seed_row_budget_workspace(base)
        self.base = str(Path(base).resolve())

    def health(self):
        with self.lock:
            ready = self.ready
        if not ready:
            return h.RawHttpResponse(503, b'{"error":"identity unavailable"}',
                                     content_type="application/json")
        _, payload = h.fleet_safety_fixture()
        payload["paths"] = {"effective_base_path": self.base,
                            "effective_masc_root": str(Path(self.base, ".masc"))}
        return h.RawHttpResponse(200, json.dumps(payload).encode(),
                                 content_type="application/json")

    def install(self, fixtures):
        fixtures["/health"] = self.health
        fixtures["/health?full=1"] = self.health

    def withdraw(self, process, fd, output, *, applied):
        with self.lock:
            self.ready = False
        # Wait for the TUI's applied state, not for the fixture to have served
        # some number of failing probes. Only complete frames count.
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: applied(screen(output)), timeout=8), screen(output)

    def confirm(self):
        with self.lock:
            self.ready = True


def screen(output):
    end = output.rfind(h.FRAME_END)
    return h.screen_text(bytes(output[:end + len(h.FRAME_END)])) if end >= 0 else b""


def run_late_voice_save(executable):
    identity = Identity()
    fixtures = voice.voice_wizard_http_fixtures()
    identity.install(fixtures)
    saved = h.GatedHttpResponse((200, {"revision": "late-written-revision"}), hold_seconds=20)
    writes = []
    probes = []

    def setup(body):
        if not body:
            return 200, voice.VOICE_SETUP_FIXTURE
        writes.append(json.loads(body))
        return saved()

    def probe(body):
        probes.append(json.loads(body))
        return 200, {"endpoints": []}

    fixtures["/api/v1/voice/setup"] = h.RequestHttpResponse(setup)
    fixtures["/api/v1/voice/probe/tts"] = h.RequestHttpResponse(probe)

    def interact(process, fd, _slave, output, _base):
        def press(value):
            return h.press_and_settle(process, fd, output, value, cap=15)

        try:
            voice.open_the_voice_pane(process, fd, output)
            press(b"e")
            press(b"\r")  # TTS -> provider
            press(b"\r")  # provider -> endpoint name
            press(b"late-endpoint")
            press(b"\r")  # name -> credential variable
            press(b"\r")  # prefilled credential -> model
            press(b"eleven_multilingual_v2")
            press(b"\r")
            press(b"late-voice")
            assert b"enter saves this" in press(b"\r"), screen(output)
            os.write(fd, b"\r")
            assert h.wait_for_fixture_event(process, fd, output, saved.requested, timeout=8)
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: "saving…".encode() in screen(output), timeout=8), screen(output)
            assert not saved.completed.is_set(), "save must remain in flight"
            # The wizard uses config_pane_title, which retains the workspace
            # badge even while this overlay owns the input and Save_sending.
            identity.withdraw(process, fd, output,
                applied=lambda shown: b"[workspace unconfirmed]" in shown)
            assert "saving…".encode() in screen(output), screen(output)
            assert not saved.completed.is_set(), "retirement must precede the save reply"
            # Retirement has already visited Save_sending. Only now does the
            # successful operation receipt create its follow-up Save_probing.
            start = len(output)
            saved.release.set()
            h.wait_for_output(process, fd, output,
                b"endpoint probe awaits confirmed workspace identity", start=start, timeout=8)
            h.drain_until_quiet(process, fd, output)
            assert b"asking the endpoints to answer" not in screen(output), screen(output)
            assert len(writes) == 1 and writes[0]["expected_revision"] == "fixture-voice-revision", writes
            assert probes == [], "an unconfirmed workspace must not receive the probe"
            press(b"\x1b")
            os.write(fd, b"q")
        finally:
            saved.release.set()

    h.run_terminal_scenario(executable,
        description="late voice save settles its locally refused probe after identity retirement",
        interact=interact, prepare_workspace=identity.prepare, http_fixtures=fixtures,
        refresh=0.2, terminal_cols=160)


def run_deletion_retry_receipt(executable):
    identity = Identity()
    fixtures = h.overview_event_http_fixtures()
    identity.install(fixtures)
    operation = "shutdown-00000000-0000-4000-8000-000000000001"
    writes = []
    reads = 0
    lock = threading.Lock()

    def inventory(removed=False, marker=None):
        return 200, {"operations": [], "errors": [], "configuration_removals": [{
            "kind": "configuration_removal", "operation_id": operation,
            "keeper_name": "alpha", "actor": "operator", "source_sha256": "a" * 64,
            "source_path": "keepers/alpha.toml", "requested_at": "2026-10-08T00:00:00Z",
            "updated_at": "2026-10-08T00:00:01Z",
            "state": {"kind": "removed" if removed else "cleanup_required",
                      "error": None if removed else "fixture cleanup failure"}}],
            "configuration_errors": [] if marker is None else [marker]}

    retired = h.GatedHttpResponse(inventory(True, "RETIRED_INVENTORY"), hold_seconds=20)
    recovered = h.GatedHttpResponse(inventory(True), subsequent_response=inventory(True), hold_seconds=20)

    def listing():
        nonlocal reads
        with lock:
            reads += 1
            count = reads
        if count == 1:
            return inventory()
        return retired() if count == 2 else recovered()

    def retry(body):
        request = json.loads(body)
        writes.append(request)
        assert request == {"keeper_name": "alpha", "operation_id": operation}, request
        return 202, {"ok": True, "accepted": True, "target_kind": "keeper",
                     "keeper_name": "alpha", "operation_id": operation}

    fixtures["/api/v1/dashboard/keepers/deletions"] = listing
    fixtures["/api/v1/dashboard/keepers/configuration-deletions/retry"] = h.RequestHttpResponse(retry)

    def interact(process, fd, _slave, output, _base):
        try:
            h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
            start = len(output)
            os.write(fd, b"D")
            h.wait_for_output(process, fd, output, b"fixture cleanup failure", start=start, timeout=8)
            os.write(fd, b"t")
            assert h.wait_for_fixture_event(process, fd, output, retired.requested, timeout=8)
            loading = "조회/재시도 중".encode()
            title = "키퍼 삭제 기록".encode()
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: title in screen(output) and loading in screen(output), timeout=8), screen(output)
            assert not retired.completed.is_set(), "the follow-up inventory must still be held"
            # This overlay has no workspace badge. Its title's loading flag
            # is the read owner: suspend_keeper_deletions_read clears it.
            # Since the GET is still held, completion cannot explain its loss.
            identity.withdraw(process, fd, output,
                applied=lambda shown: title in shown and loading not in shown)
            assert not retired.completed.is_set(), "owner retirement must precede the GET reply"
            assert b"accepted; refreshing inventory" in screen(output), screen(output)
            retired.release.set()
            assert h.wait_for_fixture_event(process, fd, output, retired.completed, timeout=8)
            h.drain_until_quiet(process, fd, output)
            shown = screen(output)
            assert b"accepted; refreshing inventory" in shown, shown
            assert operation.encode() in shown, shown
            assert b"RETIRED_INVENTORY" not in shown, shown
            assert "t:정리 재시도".encode() not in shown, shown
            os.write(fd, b"t")
            h.drain_until_quiet(process, fd, output)
            assert len(writes) == 1, writes
            identity.confirm()
            assert h.wait_for_fixture_event(process, fd, output, recovered.requested, timeout=8)
            # The accepted POST still owns its receipt until a fresh inventory
            # under restored read authority actually arrives.
            assert b"accepted; refreshing inventory" in screen(output), screen(output)
            start = len(output)
            recovered.release.set()
            h.wait_for_output(process, fd, output, "설정 삭제 및 정리 완료".encode(), start=start, timeout=8)
            h.drain_until_quiet(process, fd, output)
            assert b"accepted; refreshing inventory" not in screen(output), screen(output)
            assert "t:정리 재시도".encode() not in screen(output), screen(output)
            assert len(writes) == 1, writes
            h.press_and_settle(process, fd, output, b"\x1b")
            os.write(fd, b"q")
        finally:
            retired.release.set()
            recovered.release.set()

    h.run_terminal_scenario(executable,
        description="deletion retry acceptance survives a retired inventory and reconciles after recovery",
        interact=interact, prepare_workspace=identity.prepare, http_fixtures=fixtures,
        refresh=0.2, terminal_cols=160, terminal_rows=45)


if __name__ == "__main__":
    run_late_voice_save(os.path.abspath(sys.argv[1]))
    run_deletion_retry_receipt(os.path.abspath(sys.argv[1]))
    print("operation receipts across identity retirement: PASS", flush=True)
