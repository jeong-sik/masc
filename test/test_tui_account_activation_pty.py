"""Login save activates the owner runtime and retries activation without saving again.

Exercise the real TUI against fixture HTTP boundaries: official login, model
save, workspace identity read, resume receipt, and runtime catalogue refresh.
Refused, lost, and incomplete resume responses retain the saved configuration.
"""
from __future__ import annotations

import json
import os
import sys
import threading
from pathlib import Path

import tui_keyboard_harness as h
from tui_keyboard_runtime import (
    RUNTIME_CONFIG_RAW_PATH,
    RUNTIME_PROBE_FORCE_PATH,
    RUNTIME_PROBE_PATH,
    runtime_config_read_metadata,
    runtime_probe_response,
    runtime_resolved_response,
    runtime_resolved_runtime,
)

LOGIN = "/api/v1/setup/accounts/login"
SAVE = "/api/v1/setup/connections"
RESUME = "/api/v1/runtime/setup/resume"
SESSION = "a" * 64
ACCOUNT = "b" * 64
ACTIVE = "런타임에 활성화했습니다".encode()
FAILED = "런타임 활성화 미확인".encode()


def frame(event, data):
    return ("event: " + event + "\ndata: " + json.dumps(data) + "\n\n").encode()


def scenario(binary, outcome):
    requests = []
    saves = []
    activations = []
    ordering = []
    active = threading.Event()
    pending = h.GatedHttpResponse((200, {"runtime_ready": True,
        "exact_output_authority_available": True, "model_setup": {"status": "available"}}),
        hold_seconds=30.0)
    refreshed = {name: threading.Event() for name in ("inventory", "config", "catalog", "surface")}
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def inventory():
        if active.is_set():
            refreshed["inventory"].set()
        return 200, {
            "setup_revision": "saved-revision" if saves else "initial-revision",
            "default_runtime_selection": ["account-one.model"] if saves else [],
            "default_runtime_id": "account-one.model" if saves else None,
            "runtimes": [{"id": "account-one.model"}] if saves else [],
            "account_emails": [],
            "integrations": [{"id": "codex", "display_name": "Codex",
                              "protocol": "codex-app-server", "origin": "masc_integration"}],
        }

    fixtures["/api/v1/setup/inventory"] = inventory

    def login():
        ordering.append("login")
        yield frame("started", {"login_id": SESSION, "integration_id": "codex", "account_ref": ACCOUNT})
        yield frame("complete", {"login_id": SESSION, "integration_id": "codex",
            "account_ref": ACCOUNT, "authentication": "authenticated", "invocation_verified": False})

    fixtures[LOGIN] = h.StreamingHttpResponse(login)
    fixtures["/api/v1/setup/models"] = (200, {"models": [{
        "id": "model", "label": "Account one model", "context": 272000,
        "tools": True, "bound": False}]})

    def save(body):
        saves.append(json.loads(body))
        ordering.append("save")
        receipt = {"configured": True, "readiness": "verified", "runtime_ids": ["account-one.model"],
                   "commit": {"durability": "durable", "warnings": []}}
        if outcome == "usage_limited":
            receipt.update(readiness="usage_limited", unverified=[{
                "runtime_id": "account-one.model", "code": "quota_exhausted"}])
        return 200, receipt

    fixtures[SAVE] = h.RequestHttpResponse(save)

    def resume(body):
        assert json.loads(body) == {}, "activation has no save or login payload"
        activations.append(body)
        assert ordering[-1] == "health", "activation must recheck the workspace identity"
        assert len(saves) == 1, "activation must follow one committed save"
        ordering.append("activate")
        if len(activations) == 1:
            if outcome == "close_pending":
                result = pending()
                active.set()
                return result
            if outcome in ("refused", "close_failed"):
                return 503, {"error": "fixture-private-configuration-detail"}
            if outcome == "lost":
                return h.DroppedHttpResponse()
            if outcome == "incomplete":
                return 200, {"runtime_ready": True, "model_setup": {"status": "available"}}
        active.set()
        return 200, {"runtime_ready": True, "exact_output_authority_available": outcome != "usage_limited",
                     "model_setup": {"status": "available"}}

    fixtures[RESUME] = h.RequestHttpResponse(resume)

    def catalog():
        status, payload = runtime_resolved_response()
        if active.is_set():
            refreshed["catalog"].set()
            payload["runtimes"].append(runtime_resolved_runtime(
                "account-one.model", "Acct1", "live-model", provider_id="account-one"))
            payload["lanes"][0]["runtime_ids"].insert(0, "account-one.model")
        return status, payload

    fixtures[h.RUNTIME_RESOLVED_PATH] = catalog

    def config():
        if active.is_set():
            refreshed["config"].set()
        return 200, {**runtime_config_read_metadata(), "path": "/workspace/config/runtime.toml",
                     "source_text": '[models."account-one.model"]\nmodel = "model"\n'}

    fixtures[RUNTIME_CONFIG_RAW_PATH] = config
    fixtures[RUNTIME_PROBE_PATH] = runtime_probe_response(fresh=False)

    def surface():
        if active.is_set():
            refreshed["surface"].set()
        return runtime_probe_response(fresh=True)

    fixtures[RUNTIME_PROBE_FORCE_PATH] = surface

    def interact_steps(process, fd, _slave, output, base_path):
        # The health response is bound to the same runtime root as this TUI.
        # Record only after the screen has loaded its initial identity.
        h.tab_until(process, fd, output, b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")

        def health():
            ordering.append("health")
            return 200, {"paths": {"effective_base_path": base_path,
                "effective_masc_root": str(Path(base_path) / ".masc"), "effective_has_masc_dir": True}}

        fixtures["/health"] = health
        h.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
        h.send_and_wait(process, fd, output, b"/login codex\r", "> + 새 계정".encode())
        h.send_and_wait(process, fd, output, b"\r", b"Account one model")
        start = len(output)
        os.write(fd, b"\r")
        if outcome == "close_pending":
            assert h.wait_for_fixture_event(process, fd, output, pending.requested, timeout=5.0)
            h.send_and_wait(process, fd, output, b"\x1b", "Keepers ▸ alpha ▸ chat".encode())
            h.send_and_wait(process, fd, output, b"/login codex\r", "런타임 활성화 중입니다".encode())
            assert len(activations) == 1, "reopening restarted the pending activation"
            pending.release.set()
            h.wait_for_output(process, fd, output, ACTIVE, start=start)
        elif outcome in ("refused", "lost", "incomplete", "close_failed"):
            h.wait_for_output(process, fd, output, FAILED, start=start)
            h.drain_until_quiet(process, fd, output)
            assert len(activations) == 1, "failure must wait for the operator's retry"
            assert ACTIVE not in output[start:], "unconfirmed activation was reported as active"
            assert b"fixture-private-configuration-detail" not in output, "activation error exposed config details"
            if outcome == "close_failed":
                h.send_and_wait(process, fd, output, b"\x1b", "Keepers ▸ alpha ▸ chat".encode())
                h.send_and_wait(process, fd, output, b"/login codex\r", FAILED)
                assert len(activations) == 1, "reopening silently retried activation"
            # Enter has the same activation-only retry as r; cover both bindings.
            h.send_and_wait(process, fd, output, b"\r" if outcome == "incomplete" else b"r", ACTIVE)
        else:
            h.wait_for_output(process, fd, output, ACTIVE, start=start)
        for name, event in refreshed.items():
            assert h.wait_for_fixture_event(process, fd, output, event, timeout=5.0), f"{name} did not reload after activation"
        assert len(saves) == 1 and ordering.count("login") == 1, "activation retry duplicated save or login"
        assert len(activations) == (2 if outcome in ("refused", "lost", "incomplete", "close_failed") else 1)
        if outcome == "usage_limited":
            h.wait_for_output(process, fd, output, b"account-one.model (quota_exhausted)", start=start)
            h.wait_for_output(process, fd, output, "아직 사용할 수 없습니다".encode(), start=start)
            assert "검증하고 저장했습니다".encode() not in output[start:]
        # A successful state's refresh remains read-only.
        refreshed["inventory"].clear()
        h.send_and_wait(process, fd, output, b"r", ACTIVE)
        assert h.wait_for_fixture_event(process, fd, output, refreshed["inventory"], timeout=5.0)
        assert len(saves) == 1 and len(activations) == (2 if outcome in ("refused", "lost", "incomplete", "close_failed") else 1)
        h.send_and_wait(process, fd, output, b"\x1b", "Keepers ▸ alpha ▸ chat".encode())
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.tab_until(process, fd, output, b"MASC System")
        h.send_and_wait(process, fd, output, b"9", b"live-model")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC System")
        os.write(fd, b"q")

    def interact(process, fd, slave, output, base_path):
        try:
            interact_steps(process, fd, slave, output, base_path)
        finally:
            pending.release.set()

    h.run_terminal_scenario(binary, description=f"account save activation: {outcome}",
        interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    for outcome in ("success", "refused", "lost", "incomplete", "usage_limited", "close_pending", "close_failed"):
        scenario(binary, outcome)
    print("tui account activation: PASS (7 scenarios)")
