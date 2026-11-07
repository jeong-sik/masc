"""Read Vibe's readiness over vibe-acp without sending a prompt.

Usage: python3 -I acp-probe.py <empty-workdir>

Sends initialize, _auth/status, session/new and _account/read over stdio.
No prompt is sent, so no model call is made. MISTRAL_API_KEY is removed from
the child environment, as the lane does. Identifiers and the key suffix are
masked; a JSON-RPC error prints its code only, since its message can name
local paths. The plan title and budget numbers are printed for the
operator's own console; the evidence bundle commits only their field names
and kinds, written by hand from this output.

The call is not read-only for Vibe: _account/read rewrites Vibe's whoami
cache under ~/.vibe, and session/new takes a session lease.
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time

MASKED_KEYS = frozenset(
    {"customer_id", "sessionId", "session_id", "email", "userId", "user_id",
     "organizationId", "workspaceId", "preview", "name"}
)
CALL_TIMEOUT_S = 30.0
EXIT_TIMEOUT_S = 10.0


def mask(value: object) -> object:
    if isinstance(value, dict):
        return {k: ("***" if k in MASKED_KEYS else mask(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [mask(v) for v in value]
    return value


def shown(response: dict[str, object]) -> object:
    error = response.get("error")
    if isinstance(error, dict):
        return {"error": {"code": error.get("code")}}
    return mask(response.get("result", response))


def main() -> None:
    workdir = os.path.abspath(sys.argv[1])
    env = {k: v for k, v in os.environ.items() if k != "MISTRAL_API_KEY"}
    proc = subprocess.Popen(
        ["vibe-acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, cwd=workdir, env=env, text=True,
    )
    stdin, stdout = proc.stdin, proc.stdout
    assert stdin is not None and stdout is not None
    lines: "queue.Queue[str]" = queue.Queue()

    def pump() -> None:
        for line in stdout:
            lines.put(line)
        lines.put("")

    threading.Thread(target=pump, daemon=True).start()

    def call(request_id: int, method: str, params: dict[str, object]) -> dict[str, object]:
        stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n")
        stdin.flush()
        deadline = time.monotonic() + CALL_TIMEOUT_S
        while True:
            try:
                line = lines.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                return {"timeout": True}
            if not line:
                return {"eof": True}
            message = json.loads(line)
            is_answer = "method" not in message and ("result" in message or "error" in message)
            if is_answer and message.get("id") == request_id:
                return message

    started = time.monotonic()
    try:
        print("initialize:", json.dumps(shown(call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}}))))
        print("auth/status:", json.dumps(shown(call(2, "_auth/status", {}))))
        created = call(3, "session/new", {"cwd": workdir, "mcpServers": []})
        result = created.get("result")
        session_id = result.get("sessionId") if isinstance(result, dict) else None
        print("session/new:", "ok" if isinstance(session_id, str) else json.dumps(shown(created)))
        if isinstance(session_id, str):
            print("account/read:", json.dumps(shown(call(4, "_account/read", {"sessionId": session_id}))))
        print("seconds:", round(time.monotonic() - started, 1))
    finally:
        try:
            stdin.close()
        except BrokenPipeError:
            pass
        try:
            proc.wait(timeout=EXIT_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    print("exit:", proc.returncode)


if __name__ == "__main__":
    main()
