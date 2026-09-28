"""Four official clients: remote login input stays outside Keeper chat."""
from __future__ import annotations
import json
import os
import sys
import threading
import time
from pathlib import Path
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_account_login.ml", "bin/masc_tui.ml", "bin/masc_tui_command.ml", "bin/masc_tui_http.ml", "bin/masc_tui_types.ml", "bin/masc_tui_render.ml")
LOGIN = "/api/v1/setup/accounts/login"
SESSION = "a" * 64
ACCOUNT = "b" * 64


def frame(event, data):
    return ("event: " + event + "\ndata: " + json.dumps(data) + "\n\n").encode()


def leave_login_and_arm_quit(process, fd, output):
    # Esc closes only the login modal. Its parent is still the chat composer,
    # where q is text; return to Overview before arming the harness's exit.
    h.send_and_wait(process, fd, output, b"\x1b", "Keepers ▸ alpha ▸ chat".encode())
    h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
    h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
    os.write(fd, b"q")


def scenario(binary, client, protocol, *, delayed_save=False):
    supplied = threading.Event()
    requests = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/setup/inventory"] = (200, {"setup_revision": "fixture-revision", "default_runtime_selection": [], "runtimes": [],
        "integrations": [{"id": client, "display_name": client, "protocol": protocol}]})

    def chunks():
        yield frame("started", {"login_id": SESSION, "integration_id": client, "account_ref": ACCOUNT})
        yield frame("output", {"stream": "stdout", "text": "Open https://fixture-login.example/ and enter the returned code\n"})
        assert supplied.wait(10), "code was not forwarded to login input"
        yield frame("input_ready", {})
        yield frame("complete", {"login_id": SESSION, "integration_id": client, "account_ref": ACCOUNT,
            "authentication": "authenticated" if client in ("codex", "claude") else "login_completed",
            "invocation_verified": False})

    def accept(body):
        assert json.loads(body) == {"kind": "text", "text": "fixture-private-login-code"}
        supplied.set()
        return 202, {"accepted": True}

    fixtures[LOGIN] = h.StreamingHttpResponse(chunks)
    fixtures[LOGIN + "/" + SESSION + "/input"] = h.RequestHttpResponse(accept)
    fixtures["/api/v1/setup/models"] = (200, {"models": [{"id": "test-model", "label": "Selected account model", "context": 32768, "tools": True}]})
    def verify(_body):
        if delayed_save:
            # Deliberately exceed the old generic HTTP read deadline (10s).
            # This is a test stimulus, not a product timeout.
            time.sleep(11)
        return 200, {"configured": True, "readiness": "verified", "runtime_id": "new-runtime", "runtime_ids": ["new-runtime"]}

    fixtures["/api/v1/setup/connections"] = h.RequestHttpResponse(verify)

    def interact(process, fd, _slave, output, _base_path):
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
        h.send_and_wait(process, fd, output, ("/login " + client + "\r").encode(), b"MASC Account Login")
        h.wait_for_output(process, fd, output, "새 계정 로그인".encode(), start=0, timeout=3.0)
        h.send_and_wait(process, fd, output, b"\r", b"fixture-login.example")
        h.send_and_wait(process, fd, output, b"\x1b[200~fixture-private-login-code\x1b[201~\r", b"Selected account model")
        assert b"fixture-private-login-code" not in output, "secret echoed to terminal"
        if client == "muse":
            h.send_and_wait(process, fd, output, b"\r", "Muse 입력 한도(bytes):".encode())
            h.send_and_wait(process, fd, output, b"65536\r", "검증하고 저장했습니다".encode())
        elif delayed_save:
            start = len(output)
            os.write(fd, b"\r")
            h.wait_for_output(process, fd, output, "검증하고 저장했습니다".encode(), start=start, timeout=20.0)
        else:
            h.send_and_wait(process, fd, output, b"\r", "검증하고 저장했습니다".encode())
        calls = [(path, json.loads(body)) for path, body in requests if body and path.startswith("/api/v1/setup/")]
        save = next(body for path, body in calls if path.endswith("/connections"))
        assert save["revision"] == "fixture-revision"
        assert save["connections"][0]["source"] == {"integration_id": client, "account_ref": ACCOUNT}
        assert not any("chat/stream" in path for path, _ in requests), "login reached Keeper chat"
        leave_login_and_arm_quit(process, fd, output)

    h.run_terminal_scenario(binary, description=client + (" slow verification retains request ownership" if delayed_save else " remote login through model verification"),
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


def retry_before_started(binary):
    supplied = threading.Event()
    ready = threading.Event()
    attempts = []
    requests = []
    next_session = "c" * 64
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/setup/inventory"] = (200, {"setup_revision": "fixture-revision",
        "default_runtime_selection": [], "runtimes": [],
        "integrations": [{"id": "codex", "display_name": "codex", "protocol": "codex-app-server"}]})

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
        return h.StreamingHttpResponse(first_chunks if len(attempts) == 1 else retry_chunks)

    def accept(body):
        assert json.loads(body) == {"kind": "text", "text": "retained-private-code"}
        supplied.set()
        return 202, {"accepted": True}

    fixtures[LOGIN] = h.RequestHttpResponse(begin)
    fixtures[LOGIN + "/" + next_session + "/input"] = h.RequestHttpResponse(accept)
    fixtures[LOGIN + "/" + SESSION + "/input"] = (409, {"error": "old session must never receive input"})
    fixtures["/api/v1/setup/models"] = (200, {"models": [{"id": "test-model", "label": "Retry selected model", "context": 32768, "tools": True}]})

    def interact(process, fd, _slave, output, _base_path):
        try:
            h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
            h.send_and_wait(process, fd, output, b"/login codex\r", b"MASC Account Login")
            h.wait_for_output(process, fd, output, "새 계정 로그인".encode(), start=0, timeout=3.0)
            h.send_and_wait(process, fd, output, b"\r", "로그인 절차를 완료하지 못했습니다".encode())
            h.send_and_wait(process, fd, output, b"e", "로그인 세션 준비 중".encode())
            h.send_and_wait(process, fd, output, b"\x1b[200~retained-private-code\x1b[201~\r", "안내가 도착하면".encode())
            assert not any(path.endswith("/input") for path, _ in requests), "early code reached a previous session"
            start = len(output)
            ready.set()
            h.wait_for_output(process, fd, output, b"new-login-ready", start=start, timeout=3.0)
            h.send_and_wait(process, fd, output, b"\r", b"Retry selected model")
            assert supplied.is_set(), "new session did not receive the preserved draft"
            assert b"retained-private-code" not in output, "secret echoed to terminal"
            assert attempts == [{"integration_id": "codex"}, {"integration_id": "codex", "account_ref": ACCOUNT}]
            assert not any("chat/stream" in path for path, _ in requests)
            leave_login_and_arm_quit(process, fd, output)
        finally:
            ready.set()
            supplied.set()

    h.run_terminal_scenario(binary, description="retry preserves code before new login identity",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    for client, protocol in (("codex", "codex-app-server"), ("claude", "claude-code"),
                             ("antigravity", "antigravity-cli"), ("muse", "muse-serve")):
        scenario(str(Path(sys.argv[1]).resolve()), client, protocol)
    retry_before_started(str(Path(sys.argv[1]).resolve()))
    scenario(str(Path(sys.argv[1]).resolve()), "codex", "codex-app-server", delayed_save=True)
    print("tui account login: PASS (6 scenarios)")
