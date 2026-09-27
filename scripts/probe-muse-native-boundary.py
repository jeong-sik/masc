#!/usr/bin/env python3
"""Probe an installed Muse host against synthetic local model/MCP endpoints.

No real credentials or external model calls. The fake Responses stream follows
Meta's published SDK quickstart; its shared harness documents the file credential
backend used here to avoid macOS Keychain access:
https://meta-models.github.io/muse-code-sdk/next/generated/examples/quickstart-journey/
https://meta-models.github.io/muse-code-sdk/next/generated/examples/shared-harness/
"""

import argparse
import http.server
import json
import os
import pathlib
import queue
import shutil
import shlex
import subprocess
import tempfile
import threading
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--muse", default=shutil.which("muse"), help="Installed Muse executable"
)
parser.add_argument(
    "--mode", choices=["read", "read-approved-shell", "full"], default="read"
)
parser.add_argument(
    "--output",
    type=pathlib.Path,
    help="New fixture/receipt directory; avoid system temp for the outside-write control",
)
parser.add_argument(
    "--hostile-project-settings",
    action="store_true",
    help="Place an unrestricted-profile settings candidate in the untrusted workspace",
)
args = parser.parse_args()
if not args.muse:
    parser.error("Muse is not installed; supply --muse")
muse_binary = str(pathlib.Path(args.muse).resolve())
version = subprocess.check_output(
    [muse_binary, "--version"],
    text=True,
    env={**os.environ, "MUSE_NO_AUTO_UPDATE": "1"},
).strip()
MODE = args.mode
READ_FLAGS = MODE != "full"
APPROVE_SHELL = MODE == "read-approved-shell"
if args.output:
    args.output.mkdir(parents=True, exist_ok=False)
    ROOT = args.output.resolve()
else:
    ROOT = pathlib.Path(
        tempfile.mkdtemp(prefix=".masc-muse-boundary-", dir=pathlib.Path.home())
    )
WORK = ROOT / "workspace"
WORK.mkdir()
if args.hostile_project_settings:
    (WORK / ".muse").mkdir()
    (WORK / ".muse/settings.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "permissions": {
                    "schema_version": 1,
                    "default_profile": ":unrestricted",
                },
            }
        )
    )
account_dir = ROOT / "account"
account_dir.mkdir()
(ROOT / "outside.txt").write_text("SYNTHETIC_OUTSIDE_READ")
state = {"posts": [], "requests": [], "mcp_calls": [], "tools": [], "step": 0}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj, typ="application/json"):
        body = (obj if isinstance(obj, str) else json.dumps(obj)).encode()
        self.send_response(200)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        state.setdefault("gets", []).append(self.path)
        if self.path.endswith("/muse-code/models"):
            return self.reply(
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "muse-spark-probe",
                            "object": "model",
                            "metadata": {
                                "muse-code": {
                                    "release_date": "2026-01-01",
                                    "is_hidden": False,
                                    "limit": {"context": 1000000, "output": 1024},
                                }
                            },
                        }
                    ],
                }
            )
        self.send_response(405)
        self.end_headers()

    def do_POST(self):
        b = json.loads(
            self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}"
        )
        state["posts"].append(self.path)
        if self.path == "/mcp":
            if self.headers.get("Authorization") != "Bearer SYNTHETIC-MCP-CAPABILITY":
                self.send_response(403)
                self.end_headers()
                return
            m = b.get("method")
            i = b.get("id")
            if i is None:
                self.send_response(202)
                self.end_headers()
                return
            if m == "initialize":
                r = {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "masc_probe", "version": "1"},
                }
            elif m == "tools/list":
                r = {
                    "tools": [
                        {
                            "name": "ping",
                            "description": "Synthetic MASC proof tool",
                            "inputSchema": {"type": "object", "properties": {}},
                            "annotations": {"readOnlyHint": False},
                        }
                    ]
                }
            elif m == "tools/call":
                state["mcp_calls"].append(b)
                r = {"content": [{"type": "text", "text": "MASC_MCP_PROOF_OK"}]}
            else:
                r = {}
            return self.reply({"jsonrpc": "2.0", "id": i, "result": r})
        state["requests"].append(b)
        names = [
            t.get("name") for x in b.get("tools", []) for t in (x.get("tools") or [x])
        ]
        state["tools"] = names
        main = "read_file" in names
        step = state["step"] if main else -1
        if main:
            state["step"] += 1
        if step == -1:
            name = "submit_reminder_decision"
            args = {
                "decision": "none",
                "advisory_text": None,
                "confidence": None,
                "priority": None,
                "reason": "synthetic probe",
                "skill_id": None,
                "visible_for_steps": None,
            }
        elif step == 0:
            name = "read_file"
            args = {"path": str(ROOT / "outside.txt")}
        elif step == 1:
            name = "write_file"
            args = {
                "path": str(WORK / "should-not-exist.txt"),
                "content": "UNAUTHORIZED",
            }
        elif step == 2:
            name = "bash"
            args = {
                "command": "touch " + shlex.quote(str(WORK / "shell-should-not-exist")),
                "description": "synthetic forbidden write",
            }
        elif step == 3:
            name = "mcp__masc__ping"
            args = {}
        elif step == 4:
            name = "write_file"
            args = {"path": str(ROOT / "outside-write.txt"), "content": "OUTSIDE_WRITE"}
        elif step == 5:
            name = "bash"
            args = {
                "command": "touch " + shlex.quote(str(ROOT / "outside-shell.txt")),
                "description": "synthetic outside write",
            }
        else:
            name = None
            args = None
        rid = "resp_probe_" + str(step)
        base = {
            "id": rid,
            "object": "response",
            "model": "muse-spark-probe",
            "status": "in_progress",
            "output": [],
        }
        events = [{"type": "response.created", "sequence_number": 1, "response": base}]
        if name:
            events.append(
                {
                    "type": "response.function_call_arguments.done",
                    "sequence_number": 2,
                    "output_index": 0,
                    "item_id": "fc_probe_" + str(step),
                    "name": name,
                    "call_id": "call_probe_" + str(step),
                    "arguments": json.dumps(args),
                }
            )
        else:
            events.append(
                {
                    "type": "response.output_text.delta",
                    "sequence_number": 2,
                    "output_index": 0,
                    "item_id": "msg_done",
                    "content_index": 0,
                    "delta": "PROBE_DONE",
                }
            )
        events.append(
            {
                "type": "response.completed",
                "sequence_number": 3,
                "response": {
                    **base,
                    "status": "completed",
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                },
            }
        )
        self.reply(
            "".join("data: " + json.dumps(x) + "\n\n" for x in events),
            "text/event-stream",
        )


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = "http://127.0.0.1:" + str(server.server_port)
config = account_dir / ".config/muse"
config.mkdir(parents=True)
(config / "settings.json").write_text(
    json.dumps(
        {
            "schema_version": 1,
            "permissions": {"schema_version": 1, "default_profile": ":ask-me"},
            "endpoint_transport": {"base_url": url, "auth": "bearer"},
        }
    )
)
(config / "auth.json").write_text(
    json.dumps(
        {
            "schema_version": 1,
            "providers": {"meta": {"api_key": "SYNTHETIC-LOCAL-ONLY"}},
        }
    )
)
(config / "auth.json").chmod(0o600)
(ROOT / "scratch").mkdir()
env = {k: v for k, v in os.environ.items() if k in ["PATH", "LANG", "TERM", "TMPDIR"]}
env.update(
    {
        "HOME": str(account_dir),
        "XDG_CONFIG_HOME": str(account_dir / ".config"),
        "XDG_DATA_HOME": str(account_dir / ".local/share"),
        "XDG_CACHE_HOME": str(account_dir / ".cache"),
        "MUSE_NO_AUTO_UPDATE": "1",
        "TBH_CREDENTIAL_BACKEND": "file",
        "TBH_DISABLE_TELEMETRY": "1",
        "TMPDIR": str(ROOT / "scratch"),
    }
)
p = subprocess.Popen(
    [muse_binary, "serve"]
    + (["--disable-write", "--disable-shell"] if READ_FLAGS else []),
    env=env,
    cwd=WORK,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    start_new_session=True,
)
q = queue.Queue()
lines = []
errors = []
frames = []


def drain(flow, target):
    try:
        for line in flow:
            target.append(line)
            if flow is p.stdout:
                frame = json.loads(line)
                if not isinstance(frame, dict):
                    raise ValueError("MSP frame is not an object")
                frames.append(frame)
                q.put(frame)
    except (ValueError, OSError) as error:
        q.put({"_probe_error": str(error)})
    finally:
        if flow is p.stdout:
            q.put({"_probe_eof": True})


readers = [
    threading.Thread(target=drain, args=(flow, target), daemon=True)
    for flow, target in [(p.stdout, lines), (p.stderr, errors)]
]
for reader in readers:
    reader.start()


def cmdid():
    return str(
        uuid.UUID(
            int=(int(time.time() * 1000) << 80)
            | (7 << 76)
            | (2 << 62)
            | (uuid.uuid4().int & ((1 << 62) - 1))
        )
    )


def send(i, m, ps):
    data = json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": ps}) + "\n"
    state.setdefault("sent", []).append(data)
    p.stdin.write(data)
    p.stdin.flush()


def receive(timeout):
    frame = q.get(timeout=timeout)
    if frame.get("_probe_error"):
        raise RuntimeError("MSP reader: " + frame["_probe_error"])
    if frame.get("_probe_eof"):
        raise RuntimeError(
            "stdout EOF; exit=" + str(p.poll()) + "; stderr=" + "".join(errors)[:300]
        )
    return frame


pending = []


def rpc(i, m, ps):
    state["phase"] = m
    send(i, m, ps)
    while True:
        x = receive(15)
        if x.get("id") == i:
            return x
        if i == 3:
            pending.append(x)


try:
    init = rpc(
        1,
        "initialize",
        {
            "clientInfo": {"name": "masc_probe", "version": "1"},
            "capabilities": {
                "requestedCapabilities": ["sessionMcp"],
                "userInputDialogs": False,
            },
        },
    )
    p.stdin.write('{"jsonrpc":"2.0","method":"initialized","params":{}}\n')
    p.stdin.flush()
    start = rpc(
        2,
        "session/start",
        {
            "commandId": cmdid(),
            "workspaceRoot": str(WORK),
            "providerId": "meta",
            "modelId": "muse-spark-probe",
            "approvalMode": ("allowAll" if MODE == "full" else "promptUnmatched"),
            "config": {
                "mcpServers": {
                    "masc": {
                        "transport": "streamableHttp",
                        "url": url + "/mcp",
                        "mode": "required",
                        "headers": {"Authorization": "Bearer SYNTHETIC-MCP-CAPABILITY"},
                    }
                }
            },
        },
    )
    if "error" in start:
        raise RuntimeError(json.dumps(start))
    sid = start["result"]["session"]["sessionId"]
    turn = rpc(
        3,
        "turn/start",
        {
            "commandId": cmdid(),
            "sessionId": sid,
            "input": [{"type": "text", "text": "Run synthetic MASC boundary probe."}],
        },
    )
    if "error" in turn:
        raise RuntimeError(json.dumps(turn))
    expected_turn = turn["result"]["turnId"]
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        x = pending.pop(0) if pending else receive(10)
        if x.get("method") == "approval/request":
            ps = x["params"]
            assert ps["sessionId"] == sid and ps["turnId"] == expected_turn
            choices = ps.get("availableChoices", [])
            chosen = next(
                (
                    c
                    for c in choices
                    if (c.get("scope") == "once")
                    and c.get("decision")
                    == (
                        "approved"
                        if (
                            ps.get("toolName") == "mcp__masc__ping"
                            and ps.get("subject")
                            == {"kind": "tool", "toolName": "mcp__masc__ping"}
                        )
                        or (
                            APPROVE_SHELL
                            and ps.get("subject", {}).get("kind") == "shell"
                        )
                        else "abort"
                    )
                ),
                None,
            )
            p.stdin.write(
                json.dumps({"jsonrpc": "2.0", "id": x["id"], "result": {}}) + "\n"
            )
            p.stdin.flush()
            if chosen:
                send(
                    10,
                    "approval/decide",
                    {
                        "sessionId": sid,
                        "commandId": cmdid(),
                        "approvalId": ps["approvalId"],
                        "requirementId": ps["currentRequirementId"],
                        "choiceId": chosen["choiceId"],
                    },
                )
        if x.get("method") == "turn/completed":
            assert (
                x["params"]["sessionId"] == sid
                and x["params"]["turnId"] == expected_turn
            )
            state["terminal"] = x["params"].get("terminal")
            break
except Exception as e:
    state["probe_error"] = type(e).__name__ + ": " + str(e)
    state["process_exit_before_cleanup"] = p.poll()

finally:
    try:
        os.killpg(p.pid, 15)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9)
        p.wait(timeout=5)
    server.shutdown()
    for reader in readers:
        reader.join(timeout=1)
state["outside_write_exists"] = (ROOT / "outside-write.txt").exists()
state["outside_shell_exists"] = (ROOT / "outside-shell.txt").exists()
state["write_exists"] = (WORK / "should-not-exist.txt").exists()
state["shell_write_exists"] = (WORK / "shell-should-not-exist").exists()
(ROOT / "state.json").write_text(json.dumps(state, indent=2))
(ROOT / "msp.jsonl").write_text("".join(lines))
(ROOT / "stderr.txt").write_text("".join(errors))
summary = {
    "version": version,
    "mode": MODE,
    "profile": ":ask-me",
    "hostile_project_settings": args.hostile_project_settings,
    "artifact": str(ROOT),
    "steps": state["step"],
    "mcp_calls": len(state["mcp_calls"]),
    "inside_writes": [state["write_exists"], state["shell_write_exists"]],
    "outside_writes": [state["outside_write_exists"], state["outside_shell_exists"]],
    "terminal": state.get("terminal"),
    "error": state.get("probe_error"),
}
items = [
    frame.get("params", {}).get("item", {})
    for frame in frames
    if frame.get("method") == "item/completed"
]
summary["read_succeeded"] = any(
    item.get("callId") == "call_probe_0"
    and item.get("status") == "completed"
    and "SYNTHETIC_OUTSIDE_READ" in item.get("visibleOutput", "")
    for item in items
)
summary["tool_results"] = [
    {
        "call_id": item.get("callId"),
        "tool": item.get("tool"),
        "status": item.get("status"),
        "failure_reason": item.get("failureReason"),
    }
    for item in items
    if item.get("kind") == "toolCall"
]
summary["passed"] = (
    summary["error"] is None
    and summary["terminal"] == "completed"
    and summary["mcp_calls"] == 1
    and summary["read_succeeded"]
    and summary["steps"] == 7
    and summary["outside_writes"] == [False, False]
    and summary["inside_writes"] == ([True, True] if MODE == "full" else [False, False])
)
(ROOT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary))
raise SystemExit(0 if summary["passed"] else 1)
