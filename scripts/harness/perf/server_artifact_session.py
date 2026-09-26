"""One owned server: mutation/cold/warm HTTP and concurrent liveness receipts."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time

from linux_probe_artifact import digest, require


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def decode_response(raw):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        events = [json.loads(line[5:].strip()) for line in raw.decode().splitlines()
                  if line.startswith("data:")]
        require(len(events) == 1, "expected one JSON-RPC SSE event")
        return events[0]


def run(args):
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    identity = json.loads((args.artifact / "identity.json").read_text())
    binary_path = args.artifact / "main_eio.exe"
    require(not binary_path.is_symlink() and digest(binary_path) == identity["sha256"][binary_path.name],
            "server binary changed after artifact verification")
    binary = binary_path.resolve()
    fixture_path = args.repo / "scripts/fixtures/release-evidence/runtime.toml"
    fixture = fixture_path.read_text()
    require(fixture.count("http://127.0.0.1:9/v1") == 1, "unexpected model fixture")
    model_requests = []

    class ModelStub(http.server.BaseHTTPRequestHandler):
        def reply(self):
            model_requests.append({"method": self.command, "path": self.path})
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_GET = reply
        do_POST = reply

        def log_message(self, *_args):
            pass

    with tempfile.TemporaryDirectory(prefix="masc-server-comparison-") as temporary:
        base = Path(temporary).resolve()
        config = base / ".masc/config"
        (config / "keepers").mkdir(parents=True)
        (config / "prompts").mkdir()
        stub = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ModelStub)
        stub_thread = threading.Thread(target=stub.serve_forever, daemon=True)
        stub_thread.start()
        process = None
        try:
            endpoint = f"http://127.0.0.1:{stub.server_port}/v1"
            (config / "runtime.toml").write_text(fixture.replace("http://127.0.0.1:9/v1", endpoint))
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            require(port != 8935 and port != stub.server_port, "unexpected fixture port")
            env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8",
                   "MASC_BASE_PATH": str(base), "MASC_CONFIG_DIR": str(config),
                   "MASC_CONFIG_BOOTSTRAP": "skip", "MASC_KEEPER_AUTONOMOUS_ENABLED": "false",
                   "MASC_ORCHESTRATOR_ENABLED": "false", "MASC_GRPC_ENABLED": "0", "MASC_WS_ENABLED": "0"}
            write_json(out / "identity.json", {
                **identity, "port": port, "base": str(base), "model_endpoint": endpoint,
                "environment_keys": sorted(env), "tasks": args.tasks, "cycles": args.cycles,
                "encoding": args.encoding, "text_kind": args.text_kind,
                "runner_sha256": digest(Path(__file__)), "fixture_sha256": digest(fixture_path)})
            with (out / "server.log").open("wb") as log, (out / "requests.jsonl").open("w") as receipts:
                process = subprocess.Popen([str(binary), "--host", "127.0.0.1", "--base-path",
                                            str(base), "--port", str(port)], cwd=base, env=env,
                                           stdout=log, stderr=log, start_new_session=True)
                headers = {"Accept": "application/json, text/event-stream"}
                lock = threading.Lock()
                sequence = 0

                def request(method, path, *, payload=None, extra=None, phase=None, cycle=None):
                    body = None if payload is None else json.dumps(payload).encode()
                    hs = dict(headers if path == "/mcp" else {"Accept": "application/json"})
                    hs.update(extra or {})
                    hs.setdefault("Accept-Encoding", "identity")
                    if body is not None:
                        hs["Content-Type"] = "application/json"
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                    start = time.perf_counter_ns()
                    try:
                        connection.request(method, path, body, hs)
                        response = connection.getresponse()
                        headers_at = time.perf_counter_ns()
                        wire = response.read()
                        end = time.perf_counter_ns()
                        rh = {k.lower(): v for k, v in response.getheaders()}
                        actual_encoding = rh.get("content-encoding") or "identity"
                        accepted = actual_encoding == "identity" or (
                            hs["Accept-Encoding"] == "gzip" and actual_encoding == "gzip")
                        if not accepted:
                            if phase is not None:
                                with lock:
                                    receipts.write(json.dumps({"phase": phase, "cycle": cycle,
                                        "method": method, "path": path, "status": response.status,
                                        "requested_encoding": hs["Accept-Encoding"], "encoding": actual_encoding,
                                        "start_ns": start, "end_ns": end, "wire_bytes": len(wire),
                                        "wire_base64": base64.b64encode(wire).decode(),
                                        "error": "unaccepted response encoding"}) + "\n")
                                    receipts.flush()
                            require(False, "unaccepted response encoding; see requests.jsonl")
                        raw = gzip.decompress(wire) if rh.get("content-encoding") == "gzip" else wire
                        row = {"method": method, "path": path, "phase": phase, "cycle": cycle,
                               "status": response.status, "start_ns": start, "end_ns": end,
                               "wire_ms": (end - start) / 1e6, "headers_ms": (headers_at - start) / 1e6,
                               "body_read_ms": (end - headers_at) / 1e6,
                               "wire_bytes": len(wire), "json_bytes": len(raw),
                               "body_sha256": hashlib.sha256(raw).hexdigest(), "body_utf8": raw.decode(),
                               "encoding": rh.get("content-encoding"), "etag": rh.get("etag"),
                               "requested_encoding": hs["Accept-Encoding"],
                               "server_timing": rh.get("server-timing")}
                        if payload is not None:
                            row["request_sha256"] = hashlib.sha256(body).hexdigest()
                            row["rpc_id"] = payload["id"]
                            row["rpc_method"] = payload["method"]
                            row["tool"] = payload["params"].get("name")
                            row["arguments_sha256"] = hashlib.sha256(json.dumps(
                                payload["params"], sort_keys=True).encode()).hexdigest()
                        if phase is not None:
                            with lock:
                                receipts.write(json.dumps(row, ensure_ascii=False) + "\n")
                                receipts.flush()
                        return decode_response(raw), rh, row
                    finally:
                        connection.close()

                def rpc(method, params, *, phase, cycle=None):
                    nonlocal sequence
                    sequence += 1
                    payload = {"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}
                    result, rh, row = request("POST", "/mcp", payload=payload, phase=phase, cycle=cycle)
                    require(row["status"] == 200 and result.get("id") == sequence
                            and "error" not in result, "JSON-RPC failure; see requests.jsonl")
                    if method == "initialize":
                        headers["Mcp-Session-Id"] = rh["mcp-session-id"]
                        headers["Mcp-Protocol-Version"] = rh["mcp-protocol-version"]
                    return result["result"], row

                def tool(name, arguments, *, phase, cycle=None):
                    result, row = rpc("tools/call", {"name": name, "arguments": arguments},
                                      phase=phase, cycle=cycle)
                    require(not result.get("isError", False) and result["structuredContent"]["ok"] is True,
                            "tool failed; see requests.jsonl")
                    return result, row

                deadline = time.monotonic() + 45
                while True:
                    require(process.poll() is None, "server exited before readiness")
                    try:
                        health, _, row = request("GET", "/health?full=1")
                        if row["status"] == 200 and health.get("startup", {}).get("state_ready"):
                            break
                    except (OSError, TimeoutError, http.client.HTTPException):
                        pass
                    require(time.monotonic() < deadline, "server readiness deadline")
                    time.sleep(.1)
                write_json(out / "health-before.json", health)
                require(health["paths"]["effective_masc_root"] == str(base / ".masc")
                        and health["build"]["binary_commit"] == identity["source"]
                        and health["build"]["binary_commit_source"] == "embedded"
                        and health["build"]["executable_sha256"] == identity["sha256"][binary.name]
                        and health["keeper_fibers"] == 0, "server identity or isolation mismatch")
                primary = base / ".masc/tasks/backlog.json"
                initial_revision = json.loads(primary.read_text())["version"]
                token, _, row = request("GET", "/api/v1/dashboard/dev-token")
                require(row["status"] == 200 and isinstance(token.get("token"), str), "fixture auth failed")
                headers["Authorization"] = "Bearer " + token["token"]
                rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "isolated-server-comparison", "version": "1"}}, phase="initialize")
                listed, _ = rpc("tools/list", {}, phase="registry")
                require({"masc_add_task", "masc_batch_add_tasks"} <= {t["name"] for t in listed["tools"]},
                        "required tools absent")
                text = {"ascii": "verify ASCII payload ", "multilingual": "검증 ASCII payload "}[args.text_kind]
                for offset in range(0, args.tasks, 20):
                    tool("masc_batch_add_tasks", {"tasks": [{"title": f"Synthetic backlog {n:04d}",
                         "description": "Synthetic response fixture. " + (text + str(n) + " ") * 50,
                         "priority": 3} for n in range(offset, min(offset + 20, args.tasks))]}, phase="seed")
                extra = {"Accept-Encoding": args.encoding}
                primed, _, row = request("GET", "/api/v1/dashboard/execution", extra=extra, phase="prime")
                require(row["status"] == 200 and len(primed["tasks"]) == args.tasks, "seed count mismatch")
                generation = primed["execution_publication_generation"]
                for cycle in range(1, args.cycles + 1):
                    tool("masc_add_task", {"title": f"Synthetic invalidation {cycle:04d}",
                         "description": "Owned fixture cache invalidation", "priority": 3},
                         phase="mutation", cycle=cycle)
                    cold = None
                    for phase in ("cold", "warm"):
                        body, _, row = request("GET", "/api/v1/dashboard/execution", extra=extra,
                                               phase=phase, cycle=cycle)
                        require(row["status"] == 200 and len(body["tasks"]) == args.tasks + cycle
                                and body["execution_invalidated"] is False
                                and body["query"]["actor"] is None
                                and body["query"]["default_light_request"] is True, "execution response mismatch")
                        metrics = {part.strip().split(";", 1)[0] for part in (row["server_timing"] or "").split(",")}
                        require(("cache_compute" in metrics) == (phase == "cold"), "cold/warm cache mismatch")
                        if phase == "cold":
                            require(body["execution_publication_generation"] > generation, "generation did not advance")
                            generation = body["execution_publication_generation"]
                            cold = row["body_sha256"]
                        else:
                            require(row["body_sha256"] == cold, "warm bytes differ")
                # A separate phase; barrier overlap is client-side, not proof of
                # simultaneous work inside the server's encoder.
                with ThreadPoolExecutor(max_workers=2) as executor:
                    for cycle in range(1, args.cycles + 1):
                        barrier = threading.Barrier(2, timeout=10)

                        def mutate():
                            barrier.wait()
                            return tool("masc_add_task", {"title": f"Concurrent mutation {cycle:04d}",
                                "description": "Owned fixture liveness comparison", "priority": 3},
                                phase="concurrent_mutation", cycle=cycle)

                        def live():
                            barrier.wait()
                            return request("GET", "/health/live", phase="concurrent_liveness", cycle=cycle)

                        mutation = executor.submit(mutate)
                        liveness = executor.submit(live)
                        mutation.result()
                        live_body, _, live_row = liveness.result()
                        require(live_row["status"] == 200 and live_body.get("live") is True, "liveness failed")
                after, _, row = request("GET", "/health?full=1")
                require(row["status"] == 200 and after["keeper_fibers"] == 0
                        and after["build"]["runtime_instance_id"] == health["build"]["runtime_instance_id"],
                        "runtime changed during session")
                write_json(out / "health-after.json", after)
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            stub.shutdown()
            stub.server_close()
            stub_thread.join(timeout=5)
            cleanup = {"server_returncode": None if process is None else process.returncode,
                       "reaped": process is not None and process.poll() is not None,
                       "model_requests": model_requests, "stub_stopped": not stub_thread.is_alive()}
            write_json(out / "cleanup.json", cleanup)
            for name in ("backlog.json", "backlog.json.last-good"):
                path = base / ".masc/tasks" / name
                if path.is_file():
                    (out / name).write_bytes(path.read_bytes())
        require(cleanup["reaped"] and cleanup["server_returncode"] == 0 and cleanup["stub_stopped"],
                "server cleanup did not finish cleanly")
        require(all(x == {"method": "GET", "path": "/v1/models"} for x in model_requests),
                "unexpected model call")
        primary_bytes = (out / "backlog.json").read_bytes()
        require(primary_bytes == (out / "backlog.json.last-good").read_bytes(), "backlog copies differ")
        backlog = json.loads(primary_bytes)
        require(len(backlog["tasks"]) == args.tasks + 2 * args.cycles, "final task count mismatch")
        require(backlog["version"] == initial_revision + (args.tasks + 19) // 20 + 2 * args.cycles,
                "unexpected final revision")
        write_json(out / "success.json", {"initial_revision": initial_revision,
                   "final_revision": backlog["version"], "final_tasks": len(backlog["tasks"])})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--tasks", type=int, default=250)
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--encoding", choices=("identity", "gzip"), required=True)
    parser.add_argument("--text-kind", choices=("ascii", "multilingual"), required=True)
    args = parser.parse_args()
    require(args.tasks > 0 and args.cycles > 0, "tasks/cycles must be positive")

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        run(args)
    except BaseException as error:
        if args.output.is_dir():
            write_json(args.output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
