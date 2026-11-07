"""Read Vibe's readiness over vibe-acp without sending a prompt.

Usage: python3 -I acp-probe.py <empty-workdir>

Sends initialize, _auth/status, session/new and _account/read over stdio.
No prompt is sent, so no model call is made. MISTRAL_API_KEY is removed from
the child environment, as the lane does. Identifiers and the key suffix are
masked. The plan title and budget numbers are printed for the operator's own
console; this bundle commits only their field names and kinds.
"""

import json
import os
import subprocess
import sys
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


def main() -> None:
    workdir = os.path.abspath(sys.argv[1])
    env = {k: v for k, v in os.environ.items() if k != "MISTRAL_API_KEY"}
    proc = subprocess.Popen(
        ["vibe-acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, cwd=workdir, env=env, text=True,
    )
    stdin, stdout = proc.stdin, proc.stdout
    assert stdin is not None and stdout is not None

    def call(request_id: int, method: str, params: dict[str, object]) -> dict[str, object]:
        stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n")
        stdin.flush()
        deadline = time.time() + CALL_TIMEOUT_S
        while time.time() < deadline:
            line = stdout.readline()
            if not line:
                return {"eof": True}
            message = json.loads(line)
            if message.get("id") == request_id:
                return message
        return {"timeout": True}

    started = time.time()
    init = call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    print("initialize:", json.dumps(mask(init.get("result"))))
    print("auth/status:", json.dumps(mask(call(2, "_auth/status", {}))))
    created = call(3, "session/new", {"cwd": workdir, "mcpServers": []})
    result = created.get("result")
    session_id = result.get("sessionId") if isinstance(result, dict) else None
    print("session/new error:", json.dumps(created.get("error")))
    if isinstance(session_id, str):
        print("account/read:", json.dumps(mask(call(4, "_account/read", {"sessionId": session_id}))))
    print("seconds:", round(time.time() - started, 1))
    stdin.close()
    try:
        proc.wait(timeout=EXIT_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=EXIT_TIMEOUT_S)
    print("exit:", proc.returncode)


if __name__ == "__main__":
    main()
