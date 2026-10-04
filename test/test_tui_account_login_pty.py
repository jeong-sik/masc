"""Four official clients: remote login input stays outside Keeper chat."""
from __future__ import annotations

import json
import os
import sys
import threading
import time
from pathlib import Path

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness

LOGIN = "/api/v1/setup/accounts/login"
SESSION = "a" * 64
ACCOUNT = "b" * 64


def frame(event, data):
    return ("event: " + event + "\ndata: " + json.dumps(data) + "\n\n").encode()


def leave_login_and_arm_quit(process, fd, output):
    # Esc closes only the login modal. Its parent is still the chat composer,
    # where q is text; return to Dashboard before arming the harness's exit.
    _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", "Keepers ▸ alpha ▸ chat".encode())
    _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
    _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
    os.write(fd, b"q")


def scenario(binary, client, protocol, *, delayed_save=False, conflict_save=False, usage_limited_save=False, multi_models=False):
    supplied = threading.Event()
    requests = []
    save_attempts = []
    secret = "  한😀  é fixture-private-login-code  "
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    # How many saves each account-list read came after. The fixture server
    # records POST bodies only, so the list read is counted here.
    inventory_reads = []
    def inventory():
        inventory_reads.append(len(save_attempts))
        refreshed = conflict_save and bool(save_attempts)
        return 200, {"setup_revision": "refreshed-revision" if refreshed else "fixture-revision",
            "default_runtime_selection": ["existing-runtime"] if refreshed else [],
            "default_runtime_id": "existing-lane" if refreshed else None,
            "runtimes": [{"id": "existing-runtime"}] if refreshed else [],
            "account_emails": [],
            "integrations": [{"id": client, "display_name": client, "protocol": protocol,
                              "origin": "masc_integration"}]}
    fixtures["/api/v1/setup/inventory"] = inventory

    def chunks():
        yield frame("started", {"login_id": SESSION, "integration_id": client, "account_ref": ACCOUNT})
        # Coloured the way Codex colours its device link.
        yield frame("output", {"stream": "stdout", "text": "Open \x1b[94mhttps://fixture-login.example/\x1b[0m and enter the returned code\n"})
        assert supplied.wait(10), "code was not forwarded to login input"
        yield frame("input_ready", {})
        yield frame("complete", {"login_id": SESSION, "integration_id": client, "account_ref": ACCOUNT,
            "authentication": "authenticated" if client in ("codex", "claude") else "login_completed",
            "invocation_verified": False})

    def accept(body):
        assert json.loads(body) == {"kind": "text", "text": secret}
        supplied.set()
        return 202, {"accepted": True}

    fixtures[LOGIN] = _keyboard_harness.StreamingHttpResponse(chunks)
    fixtures[LOGIN + "/" + SESSION + "/input"] = _keyboard_harness.RequestHttpResponse(accept)
    catalog = [{"id": "test-model", "label": "Selected account model", "context": 32768, "tools": True, "bound": False}]
    if multi_models:
        catalog = [catalog[0],
            {"id": "unsupported-model", "label": "Unsupported account model", "context": 32768, "tools": False, "bound": False},
            {"id": "second-model", "label": "Second account model", "context": 65536, "tools": True, "bound": False}]
    fixtures["/api/v1/setup/models"] = (200, {"models": catalog})
    def verify(body):
        save_attempts.append(json.loads(body))
        if conflict_save and len(save_attempts) == 1:
            return 409, {"error": "configuration revision changed"}
        if multi_models and len(save_attempts) == 1:
            return 502, {"error": 'Runtime "codex_x.test-model_12345678" did not pass response and tool verification (provider_rejected)'}
        if delayed_save:
            # Deliberately exceed the old generic HTTP read deadline (10s).
            # This is a test stimulus, not a product timeout.
            time.sleep(11)
        if usage_limited_save:
            return 200, {"configured": True, "validation": "passed", "readiness": "usage_limited",
                         "runtime_id": "new-runtime", "runtime_ids": ["new-runtime"],
                         "unverified": [{"runtime_id": "new-runtime", "code": "quota_exhausted",
                                         "message": "fixture quota", "detail": None}]}
        return 200, {"configured": True, "readiness": "verified", "runtime_id": "new-runtime", "runtime_ids": ["new-runtime"]}

    fixtures["/api/v1/setup/connections"] = _keyboard_harness.RequestHttpResponse(verify)

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
        _keyboard_harness.send_and_wait(process, fd, output, ("/login " + client + "\r").encode(), b"MASC Account Login")
        _keyboard_harness.wait_for_output(process, fd, output, "새 계정 로그인".encode(), start=0, timeout=3.0)
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"fixture-login.example")
        # The harness workspace label (WORKSPACE_PAYLOAD) is an OSC 8 string the
        # TUI always shows as "\x1B]8;;...", so look for the fixture's own codes.
        for code in (b"\\x1B[94m", b"\\x1B[0m"):
            assert code not in output, "the client's colour code was drawn as text"
        # Exercise main-loop routing, including rejection before the byte-exact paste.
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[200~first\nsecond\x1b[201~", "여러 줄이나 제어 문자".encode())
        assert not supplied.is_set(), "rejected multiline credential was sent"
        model_frame = _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[200~" + (secret + "\r\n").encode() + b"\x1b[201~\r", b"Selected account model")
        assert b"fixture-private-login-code" not in output, "secret echoed to terminal"
        if multi_models:
            plain = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(model_frame))
            for needle in (b"[x] Selected account model", b"[ ] Unsupported account model", b"[x] Second account model", "도구 호출 미지원".encode()):
                assert needle in plain, f"model choice or refusal missing: {needle!r}: {plain!r}"
        if multi_models:
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"test-model_12345678")
            assert len(save_attempts) == 1, "verification failure was retried without a choice"
            _keyboard_harness.send_and_wait(process, fd, output, b"r", "최신 설정을 읽었습니다".encode())
            _keyboard_harness.send_and_wait(process, fd, output, b" ", b"[ ] Selected account model")
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "검증하고 저장했습니다".encode())
            assert len(save_attempts) == 2, "operator retry did not save once"
            assert [m["id"] for m in save_attempts[1]["connections"][0]["models"]] == ["second-model"]
        elif conflict_save:
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "설정을 새로 읽은 뒤 다시 저장".encode())
            assert b"configuration revision changed" in output, "the server's refusal reason was not drawn"
            assert len(save_attempts) == 1, "failed save retried without operator approval"
            _keyboard_harness.send_and_wait(process, fd, output, b"r", "최신 설정을 읽었습니다".encode())
            assert len(save_attempts) == 1, "refresh silently retried save"
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "검증하고 저장했습니다".encode())
            assert len(save_attempts) == 2
            assert save_attempts[1]["revision"] == "refreshed-revision"
            assert save_attempts[1]["default_runtime_id"] == "existing-lane"
            assert save_attempts[1]["selection"][0] == {"runtime_id": "existing-runtime"}
            assert save_attempts[1]["connections"][0]["source"] == {"integration_id": client, "account_ref": ACCOUNT}
            assert save_attempts[1]["connections"][0]["models"] == save_attempts[0]["connections"][0]["models"]
            assert not any(path == LOGIN + "/" + SESSION for path, _ in requests), "save recovery read login receipt instead of configuration"
        elif usage_limited_save:
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"new-runtime (quota_exhausted)")
            # The save re-reads the list; the unmeasured account must outlive it.
            deadline = time.monotonic() + 5.0
            while not any(saves > 0 for saves in inventory_reads):
                if time.monotonic() > deadline:
                    raise AssertionError("the save did not re-read the account list")
                time.sleep(0.05)
            _keyboard_harness.drain_until_quiet(process, fd, output)
            assert "검증하고 저장했습니다".encode() not in output, "an unmeasured save was reported as verified"
        elif delayed_save:
            start = len(output)
            os.write(fd, b"\r")
            _keyboard_harness.wait_for_output(process, fd, output, "검증하고 저장했습니다".encode(), start=start, timeout=20.0)
        else:
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "검증하고 저장했습니다".encode())
        calls = [(path, json.loads(body)) for path, body in requests if body and path.startswith("/api/v1/setup/")]
        save = next(body for path, body in calls if path.endswith("/connections"))
        assert save["revision"] == "fixture-revision"
        assert save["connections"][0]["source"] == {"integration_id": client, "account_ref": ACCOUNT}
        if multi_models:
            assert [model["id"] for model in save["connections"][0]["models"]] == ["test-model", "second-model"]
            assert save["selection"] == [{"connection": 0, "model": 0}, {"connection": 0, "model": 1}]
            assert "모델 2개 검증 중".encode() in output, "save did not name the verification count"
        assert not any("chat/stream" in path for path, _ in requests), "login reached Keeper chat"
        leave_login_and_arm_quit(process, fd, output)

    _keyboard_harness.run_terminal_scenario(binary, description=client + (" selects two of three models" if multi_models else " usage-limited save names the unmeasured runtime" if usage_limited_save else " save conflict refresh retains account and model" if conflict_save else " slow verification retains request ownership" if delayed_save else " remote login through model verification"),
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


def reopen_existing_without_login(binary):
    requests = []
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/setup/inventory"] = (200, {
        "setup_revision": "fixture-revision", "default_runtime_selection": ["runtime-a", "runtime-b"],
        "runtimes": [
            {"id": "runtime-a", "provider_id": "codex_hA", "model": "bound-a"},
            {"id": "runtime-b", "provider_id": "codex_hB", "model": "bound-b"}],
        "account_emails": [], "integrations": [
            {"id": "codex_hA", "display_name": "Codex account A",
             "protocol": "codex-app-server", "origin": "runtime_config"},
            {"id": "codex_hB", "display_name": "Codex account B",
             "protocol": "codex-app-server", "origin": "runtime_config"}]})

    def select(body):
        assert json.loads(body) == {"integration_id": "codex_hA"}
        return 200, {"account_ref": ACCOUNT, "account_selected": True}

    def models(body):
        assert json.loads(body) == {"integration_id": "codex_hA", "account_ref": ACCOUNT}
        return 200, {"models": [
            {"id": "bound-a", "label": "Bound model A", "context": 32768, "tools": True, "bound": True},
            {"id": "bound-b", "label": "Bound model B", "context": 32768, "tools": True, "bound": True},
            {"id": "new-model", "label": "New account model", "context": 65536, "tools": True, "bound": False}]}

    fixtures["/api/v1/setup/accounts/select"] = _keyboard_harness.RequestHttpResponse(select)
    fixtures["/api/v1/setup/accounts/login"] = (500, {"error": "login must not start"})
    fixtures["/api/v1/setup/models"] = _keyboard_harness.RequestHttpResponse(models)

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
        account_frame = _keyboard_harness.send_and_wait(
            process, fd, output, b"/login codex\r", "> + 새 계정".encode())
        assert "새 계정 로그인".encode() in _keyboard_chat.unwrapped(_keyboard_harness.screen_text(account_frame))
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"> Codex account A")
        frame = _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"New account model")
        plain = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(frame))
        assert "[연결됨] Bound model A".encode() in plain and "[연결됨] Bound model B".encode() in plain, "connected models were hidden"
        assert b"[x] New account model" in plain, "the remaining model was not preselected"
        assert not any(path == LOGIN for path, _ in requests), "opening an existing account started login"
        leave_login_and_arm_quit(process, fd, output)

    _keyboard_harness.run_terminal_scenario(binary, description="existing account opens remaining models without login",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


def retry_before_started(binary):
    supplied = threading.Event()
    ready = threading.Event()
    attempts = []
    requests = []
    next_session = "c" * 64
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/setup/inventory"] = (200, {"setup_revision": "fixture-revision",
        "default_runtime_selection": [], "runtimes": [], "account_emails": [],
        "integrations": [{"id": "codex", "display_name": "codex", "protocol": "codex-app-server",
                          "origin": "masc_integration"}]})

    def first_chunks():
        receipt = {"login_id": SESSION, "integration_id": "codex", "account_ref": ACCOUNT,
                   "invocation_verified": False, "status": "failed"}
        yield frame("started", receipt)
        yield frame("error", receipt)

    def retry_chunks():
        assert ready.wait(10), "early code was not retained before the new session"
        yield frame("started", {"login_id": next_session, "integration_id": "codex", "account_ref": ACCOUNT})
        yield frame("output", {"stream": "stdout", "text": "new-login-ready\n"})
        assert supplied.wait(10), "retained code was not submitted to the new session"
        yield frame("complete", {"integration_id": "codex", "account_ref": ACCOUNT,
            "authentication": "authenticated", "invocation_verified": False})

    def begin(body):
        attempts.append(json.loads(body))
        return _keyboard_harness.StreamingHttpResponse(first_chunks if len(attempts) == 1 else retry_chunks)

    def accept(body):
        assert json.loads(body) == {"kind": "text", "text": "retained-private-code"}
        supplied.set()
        return 202, {"accepted": True}

    fixtures[LOGIN] = _keyboard_harness.RequestHttpResponse(begin)
    fixtures[LOGIN + "/" + next_session + "/input"] = _keyboard_harness.RequestHttpResponse(accept)
    fixtures[LOGIN + "/" + SESSION + "/input"] = (409, {"error": "old session must never receive input"})
    fixtures["/api/v1/setup/models"] = (200, {"models": [{"id": "test-model", "label": "Retry selected model", "context": 32768, "tools": True, "bound": False}]})

    def interact(process, fd, _slave, output, _base_path):
        try:
            _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
            _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
            _keyboard_harness.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"/login codex\r", b"MASC Account Login")
            _keyboard_harness.wait_for_output(process, fd, output, "새 계정 로그인".encode(), start=0, timeout=3.0)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", "로그인 절차를 완료하지 못했습니다".encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"e", "로그인 세션 준비 중".encode())
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[200~retained-private-code\x1b[201~\r", "안내가 도착하면".encode())
            assert not any(path.endswith("/input") for path, _ in requests), "early code reached a previous session"
            start = len(output)
            ready.set()
            _keyboard_harness.wait_for_output(process, fd, output, b"new-login-ready", start=start, timeout=3.0)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Retry selected model")
            assert supplied.is_set(), "new session did not receive the preserved draft"
            assert b"retained-private-code" not in output, "secret echoed to terminal"
            assert attempts == [{"integration_id": "codex"}, {"integration_id": "codex", "account_ref": ACCOUNT}]
            assert not any("chat/stream" in path for path, _ in requests)
            leave_login_and_arm_quit(process, fd, output)
        finally:
            ready.set()
            supplied.set()

    _keyboard_harness.run_terminal_scenario(binary, description="retry preserves code before new login identity",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    for client, protocol in (("codex", "codex-app-server"), ("claude", "claude-code"),
                             ("antigravity", "antigravity-cli"), ("muse", "muse-serve")):
        scenario(str(Path(sys.argv[1]).resolve()), client, protocol)
    retry_before_started(str(Path(sys.argv[1]).resolve()))
    scenario(str(Path(sys.argv[1]).resolve()), "codex", "codex-app-server", delayed_save=True)
    scenario(str(Path(sys.argv[1]).resolve()), "codex", "codex-app-server", conflict_save=True)
    scenario(str(Path(sys.argv[1]).resolve()), "claude", "claude-code", usage_limited_save=True)
    scenario(str(Path(sys.argv[1]).resolve()), "codex", "codex-app-server", multi_models=True)
    reopen_existing_without_login(str(Path(sys.argv[1]).resolve()))
    print("tui account login: PASS (10 scenarios)")
