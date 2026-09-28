"""Four official clients: remote login input stays outside Keeper chat."""
from __future__ import annotations
import json
import os
import sys
import threading
from pathlib import Path
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_account_login.ml", "bin/masc_tui.ml", "bin/masc_tui_command.ml", "bin/masc_tui_http.ml", "bin/masc_tui_types.ml", "bin/masc_tui_render.ml")
LOGIN = "/api/v1/setup/accounts/login"
SESSION = "a" * 64
ACCOUNT = "b" * 64


def frame(event, data):
    return ("event: " + event + "\ndata: " + json.dumps(data) + "\n\n").encode()


def scenario(binary, client, protocol):
    supplied = threading.Event()
    requests = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
    fixtures["/api/v1/setup/inventory"] = (200, {"setup_revision": "fixture-revision", "runtimes": [],
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
    fixtures["/api/v1/setup/connections"] = (200, {"configured": True, "readiness": "verified", "runtime_id": "new-runtime", "runtime_ids": ["new-runtime"]})

    def interact(process, fd, _slave, output, _base_path):
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
        h.send_and_wait(process, fd, output, ("/login " + client + "\r").encode(), b"MASC Account Login")
        h.wait_for_output(process, fd, output, "새 계정 로그인".encode())
        h.send_and_wait(process, fd, output, b"\r", b"fixture-login.example")
        h.send_and_wait(process, fd, output, b"\x1b[200~fixture-private-login-code\x1b[201~\r", b"Selected account model")
        assert b"fixture-private-login-code" not in output, "secret echoed to terminal"
        if client == "muse":
            h.send_and_wait(process, fd, output, b"\r", "Muse 입력 한도(bytes):".encode())
            h.send_and_wait(process, fd, output, b"65536\r", "검증하고 저장했습니다".encode())
        else:
            h.send_and_wait(process, fd, output, b"\r", "검증하고 저장했습니다".encode())
        calls = [(path, json.loads(body)) for path, body in requests if body and path.startswith("/api/v1/setup/")]
        save = next(body for path, body in calls if path.endswith("/connections"))
        assert save["revision"] == "fixture-revision"
        assert save["connections"][0]["source"] == {"integration_id": client, "account_ref": ACCOUNT}
        assert not any("chat/stream" in path for path, _ in requests), "login reached Keeper chat"
        os.write(fd, b"\x1b")
        h.drain_until_quiet(process, fd, output)
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description=client + " remote login through model verification",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    for client, protocol in (("codex", "codex-app-server"), ("claude", "claude-code"),
                             ("antigravity", "antigravity-cli"), ("muse", "muse-serve")):
        scenario(str(Path(sys.argv[1]).resolve()), client, protocol)
    print("tui account login: PASS (4 scenarios)")
