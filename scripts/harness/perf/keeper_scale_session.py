#!/usr/bin/env python3
"""Owned loopback Keeper/model/queue workload using an installed binary.

No build, operator credentials, live workspace, or sandbox execution. Keepers
declare the lazy microVM lane; its image pin is fixture metadata, not evidence
that a guest/image exists. The scripted provider emits only final text. Queue
batching is observed rather than forced into one model call per message.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import concurrent.futures
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
from urllib.parse import urlsplit
import uuid


class ProbeError(RuntimeError):
    def __init__(self, detail, row=None):
        super().__init__(detail)
        self.row = row


def require(condition, detail):
    if not condition:
        raise ProbeError(detail)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def denied_inventory_kind(row, guard_dir, names):
    """Classify denied observations only; wrappers still refuse every command."""
    argv = row.get("argv", [])
    if not argv:
        return None
    command = Path(argv[0])
    if command.parent != guard_dir:
        return None
    if command.name == "container" and argv[1:] == ["list", "--all", "--format", "json"]:
        return "container_list"
    if (command.name == "nerdctl" and len(argv) == 6
            and argv[1:5] == ["ps", "-a", "--no-trunc", "--format"]):
        return "nerdctl_ps"
    if command.name == "container" and len(argv) == 4 and argv[1:3] == ["volume", "inspect"]:
        expected = {"masc-keeper-" + kind + "-" + name for kind in ("work", "build") for name in names}
        if argv[3] in expected:
            return "container_volume_inspect"
    return None


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)
    elif isinstance(value, str):
        for line in value.splitlines():
            try:
                decoded = json.loads(line)
            except ValueError:
                continue
            if not isinstance(decoded, str):
                yield from objects(decoded)


def decode_rpc(raw, request_id):
    try:
        document = json.loads(raw)
    except ValueError:
        events = []
        for block in raw.decode().replace("\r\n", "\n").split("\n\n"):
            data = "\n".join(line[5:].lstrip() for line in block.splitlines()
                             if line.startswith("data:"))
            if data:
                events.append(json.loads(data))
        matches = [event for event in events if event.get("id") == request_id]
        require(len(matches) == 1, "MCP response has no unique matching result")
        document = matches[0]
    require(document.get("id") == request_id and "error" not in document,
            "JSON-RPC failed; inspect requests.jsonl")
    return document["result"]


class Client:
    def __init__(self, port, token, output, timeout):
        self.port, self.token, self.output, self.timeout = port, token, output, timeout
        self.sequence = 0
        self.sequence_lock = threading.Lock()
        self.log_lock = threading.Lock()
        self.session = None
        self.protocol = "2025-11-25"

    def request(self, method, path, payload=None, phase=None):
        headers = {"Accept": "application/json, text/event-stream", "Accept-Encoding": "identity"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if self.session and path == "/mcp":
            headers.update({"Mcp-Session-Id": self.session,
                            "Mcp-Protocol-Version": self.protocol})
        body = None if payload is None else json.dumps(payload).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        client = http.client.HTTPConnection("127.0.0.1", self.port, timeout=self.timeout)
        started = time.perf_counter_ns()
        row = {"method": method, "path": path, "phase": phase, "start_ns": started}
        if payload is not None:
            row["payload"] = payload
        try:
            client.request(method, path, body, headers)
            response = client.getresponse()
            wire = response.read()
            finished = time.perf_counter_ns()
            row.update(status=response.status, end_ns=finished,
                       wire_ms=(finished-started)/1e6, wire_bytes=len(wire),
                       body_utf8=wire.decode(), body_sha256=hashlib.sha256(wire).hexdigest(),
                       server_timing=response.getheader("Server-Timing"))
            row["rate_headers"] = {key: value for key, value in response.getheaders()
                                   if key.lower().startswith("x-ratelimit")
                                   or key.lower() == "retry-after"}
            if response.status != 200:
                raise ProbeError("HTTP failure; inspect requests.jsonl", row=row)
            return wire, dict(response.getheaders()), row
        except (OSError, http.client.HTTPException) as error:
            row.update(error=type(error).__name__, error_detail=str(error),
                       end_ns=time.perf_counter_ns())
            raise
        finally:
            client.close()
            if phase is not None:
                with self.log_lock, (self.output / "requests.jsonl").open("a") as log:
                    log.write(json.dumps(row, ensure_ascii=False) + "\n")

    def get(self, path, phase=None):
        raw, _, row = self.request("GET", path, phase=phase)
        return json.loads(raw), row

    def rpc(self, method, params, phase):
        with self.sequence_lock:
            self.sequence += 1
            request_id = self.sequence
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        first_attempt = time.perf_counter_ns()
        deadline = time.monotonic() + self.timeout
        retries = []
        while True:
            try:
                raw, headers, row = self.request("POST", "/mcp", payload, phase)
                break
            except ProbeError as error:
                # Server_auth rejects 429 before tool dispatch. No ambiguous
                # transport/server failures are retried, and limits stay on.
                failed = error.row
                if failed is None or failed.get("status") != 429:
                    raise
                raw_retry = next((value for key, value in failed["rate_headers"].items()
                                  if key.lower() == "retry-after"), None)
                delay, source = 1.0, "client_fallback_no_retry_after"
                if raw_retry is not None:
                    try:
                        delay = float(raw_retry)
                        require(math.isfinite(delay) and delay >= 0, "invalid Retry-After")
                        source = "server_retry_after_seconds"
                    except ValueError:
                        until = parsedate_to_datetime(raw_retry)
                        require(until.tzinfo is not None, "Retry-After date has no timezone")
                        delay = max(0.0, until.timestamp() - time.time())
                        source = "server_retry_after_date"
                require(time.monotonic() + delay < deadline, "rate-limit observation deadline")
                retry = {"request_id": request_id, "phase": phase, "raw_retry_after": raw_retry,
                         "delay_s": delay, "source": source, "wait_started_ns": time.perf_counter_ns()}
                time.sleep(delay)
                retry["wait_finished_ns"] = time.perf_counter_ns()
                retries.append(retry)
                with self.log_lock, (self.output / "rate-limit-waits.jsonl").open("a") as log:
                    log.write(json.dumps(retry) + "\n")
        row["first_attempt_to_response_ms"] = (time.perf_counter_ns() - first_attempt)/1e6
        with self.log_lock, (self.output / "rpc-intervals.jsonl").open("a") as log:
            log.write(json.dumps({"request_id": request_id, "phase": phase,
                "tool": params.get("name"), "total_ms": row["first_attempt_to_response_ms"],
                "successful_attempt_wire_ms": row["wire_ms"], "rejected_429_count": len(retries),
                "rate_wait_s": sum((item["wait_finished_ns"] - item["wait_started_ns"])/1e9
                                   for item in retries)}) + "\n")
        result = decode_rpc(raw, request_id)
        if method == "initialize":
            lowered = {k.lower(): v for k, v in headers.items()}
            self.session = lowered.get("mcp-session-id")
            self.protocol = lowered.get("mcp-protocol-version", self.protocol)
            require(self.session, "MCP initialize omitted its session")
        return result, row

    def tool(self, name, arguments, phase):
        result, row = self.rpc("tools/call", {"name": name, "arguments": arguments}, phase)
        require(not result.get("isError", False), "tool failure; inspect requests.jsonl")
        data = result.get("structuredContent")
        if data is None:
            text = "\n".join(item["text"] for item in result.get("content", [])
                             if item.get("type") == "text")
            data = json.loads(text)
        return data, row


class Fixture:
    def __init__(self, output, marker, keepers, delay_ms):
        self.output, self.marker, self.keepers = output, marker, set(keepers)
        self.delay_ms = delay_ms
        self.release = threading.Event()
        self.lock = threading.Lock()
        self.requests, self.errors, self.active = [], [], 0
        self.max_active = 0
        self.handler_count = 0

    def serve(self):
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(30)

            def log_message(self, *_args):
                pass

            def send(self, status, data, content_type="application/json"):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path != "/v1/models":
                    with fixture.lock:
                        fixture.errors.append({"method": "GET", "path": self.path})
                    return self.send(404, b'{}')
                self.send(200, json.dumps({"object": "list", "data": [{
                    "id": "deepseek-v4.1-flash", "object": "model", "owned_by": "fixture"}]}).encode())

            def do_POST(self):
                started = time.perf_counter_ns()
                row = {"path": self.path, "start_ns": started}
                active = False
                try:
                    require(self.path == "/v1/chat/completions", "unexpected provider route")
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    row["request"] = request
                    require(request.get("model") == "deepseek-v4.1-flash", "unexpected provider model")
                    messages = [m for m in request.get("messages", []) if m.get("role") == "user"]
                    require(messages, "provider input has no user message")
                    # The runtime can append recall/context as another user
                    # message. Select the latest typed workload message, not
                    # whichever message happens to be last on the wire.
                    probes = []
                    for message in reversed(messages):
                        probes = [item for item in objects(message.get("content"))
                                  if item.get("schema") == "masc.keeper-scale-input.v1"
                                  and item.get("marker") == fixture.marker]
                        if probes:
                            break
                    require(probes, "provider input has no typed workload input")
                    names = {item.get("keeper") for item in probes}
                    require(len(names) == 1 and names <= fixture.keepers, "provider input mixes or invents Keeper identity")
                    name = next(iter(names))
                    sequences = [item["sequence"] for item in probes]
                    require(all(type(n) is int and n > 0 for n in sequences)
                            and len(sequences) == len(set(sequences)), "invalid workload sequences")
                    row.update(keeper=name, sequences=sequences)
                    with fixture.lock:
                        fixture.active += 1
                        active = True
                        fixture.max_active = max(fixture.max_active, fixture.active)
                        fixture.requests.append(row)
                        with (fixture.output / "model-requests.jsonl").open("a") as log:
                            log.write(json.dumps(row, ensure_ascii=False) + "\n")
                    fixture.release.wait()
                    if fixture.delay_ms:
                        time.sleep(fixture.delay_ms/1000)
                    reply = json.dumps({"schema": "masc.keeper-scale-reply.v1",
                                        "marker": fixture.marker, "keeper": name,
                                        "sequences": sequences}, sort_keys=True)
                    response = {"id": "fixture-" + uuid.uuid4().hex,
                                "object": "chat.completion", "model": request["model"],
                                "choices": [{"index": 0, "message": {
                                    "role": "assistant", "content": reply}, "finish_reason": "stop"}],
                                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
                    if request.get("stream"):
                        chunks = [{"id": response["id"], "object": "chat.completion.chunk",
                            "model": request["model"], "choices": [{"index": 0,
                                "delta": {"role": "assistant", "content": reply}, "finish_reason": None}]},
                            {"id": response["id"], "object": "chat.completion.chunk",
                             "model": request["model"], "choices": [{"index": 0, "delta": {},
                                "finish_reason": "stop"}], "usage": response["usage"]}]
                        data = ("".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                                + "data: [DONE]\n\n").encode()
                        self.send(200, data, "text/event-stream")
                    else:
                        self.send(200, json.dumps(response).encode())
                    row["end_ns"] = time.perf_counter_ns()
                except (ProbeError, ValueError, KeyError, OSError) as error:
                    row.update(error=type(error).__name__, detail=str(error))
                    with fixture.lock:
                        fixture.errors.append(row.copy())
                    try:
                        self.send(500, json.dumps({"error": {"message": str(error)}}).encode())
                    except OSError:
                        pass
                finally:
                    if active:
                        with fixture.lock:
                            fixture.active -= 1
                    with fixture.lock, (fixture.output / "model-outcomes.jsonl").open("a") as log:
                        log.write(json.dumps(row, ensure_ascii=False) + "\n")

        class Server(ThreadingHTTPServer):
            daemon_threads = False
            block_on_close = True
            request_queue_size = max(5, len(fixture.keepers))

            def process_request_thread(self, request, client_address):
                with fixture.lock:
                    fixture.handler_count += 1
                try:
                    super().process_request_thread(request, client_address)
                finally:
                    with fixture.lock:
                        fixture.handler_count -= 1

        server = Server(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread


def wait_for(description, predicate, process, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while True:
        require(process.poll() is None, "owned server exited while waiting for " + description)
        last = predicate()
        if last:
            return last
        require(time.monotonic() < deadline, "observation deadline for " + description)
        time.sleep(.1)


def run(args, owner):
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    shutil.copy2(Path(__file__), out / Path(__file__).name)
    binary = args.binary.resolve(strict=True)
    pinned = out / "masc-installed-copy"
    shutil.copy2(binary, pinned)
    pinned.chmod(0o700)
    binary_hash = digest(binary)
    require(digest(pinned) == binary_hash, "binary changed while copied")
    base = Path(tempfile.mkdtemp(prefix="masc-keeper-scale-")).resolve()
    owner["base"] = base
    config = base / ".masc/config"
    (config / "keepers").mkdir(parents=True)
    (config / "prompts").mkdir()
    home = base / "home"
    home.mkdir()
    names = [f"scale-keeper-{index:04d}" for index in range(args.keepers)]
    marker = uuid.uuid4().hex
    fixture = Fixture(out, marker, names, args.model_delay_ms)
    owner["fixture"] = fixture
    model, model_thread = fixture.serve()
    owner.update(model=model, model_thread=model_thread)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    runtime_fixture = args.repo / "scripts/fixtures/release-evidence/runtime.toml"
    runtime = runtime_fixture.read_text()
    require(runtime.count("http://127.0.0.1:9/v1") == 1, "release fixture model endpoint changed")
    require(runtime.count("streaming = true") == 1
            and runtime.count("max-concurrent = 1") == 1, "release fixture replacement scope changed")
    runtime = runtime.replace("http://127.0.0.1:9/v1", f"http://127.0.0.1:{model.server_port}/v1")
    runtime = runtime.replace("streaming = true", "streaming = false")
    runtime = runtime.replace("max-concurrent = 1", f"max-concurrent = {args.keepers}")
    parsed = tomllib.loads(runtime)
    require(set(parsed["providers"]) == {"ollama_cloud"}, "fixture added an unreviewed provider")
    provider = parsed["providers"]["ollama_cloud"]
    endpoint = urlsplit(provider["endpoint"])
    require(endpoint.scheme == "http" and endpoint.hostname == "127.0.0.1"
            and endpoint.port == model.server_port and endpoint.path == "/v1"
            and provider["credentials"] == {"type": "inline", "value": "release-evidence-loopback"}
            and parsed["ollama_cloud"]["deepseek-v4.1-flash"]["max-concurrent"] == args.keepers,
            "fixture endpoint, credential or concurrency isolation differs")
    (config / "runtime.toml").write_text(runtime)
    (config / "sandbox-image-builds.toml").write_text(
        '[images.base.apple_container]\nreference = "keeper-scale-unused:fixture"\n')
    write_json(out / "workload.json", {"keepers": names, "messages_per_keeper": args.messages_per_keeper,
        "marker": marker, "model_delay_ms": args.model_delay_ms,
        "scope": "Real Keeper model turns and durable chat operations, no sandbox or external tools; multiple queued inputs may batch."})
    shutil.copytree(config, out / "initial-config")
    # Unexpected guest launch must fail inside this fixture, never find a
    # real host daemon or SSH configuration through the inherited PATH.
    guard_dir = base / "deny-guest-commands"
    guard_dir.mkdir()
    guard_log = base / "guest-command-attempts.jsonl"
    guard_body = ("#!" + sys.executable + "\nimport json,sys,time\n"
                  "with open(" + repr(str(guard_log)) + ", 'a') as log:\n"
                  "    log.write(json.dumps({'argv':sys.argv,'time_ns':time.time_ns()})+'\\n')\n"
                  "sys.exit(126)\n")
    for command in ("docker", "container", "msb", "nerdctl", "ssh"):
        path = guard_dir / command
        path.write_text(guard_body)
        path.chmod(0o700)
    env = {"PATH": str(guard_dir) + os.pathsep + os.environ["PATH"], "LANG": "C.UTF-8", "HOME": str(home),
           "MASC_BASE_PATH": str(base), "MASC_CONFIG_DIR": str(config),
           "MASC_CONFIG_BOOTSTRAP": "skip", "MASC_KEEPER_AUTONOMOUS_ENABLED": "true",
           "MASC_GRPC_ENABLED": "0", "MASC_WS_ENABLED": "0"}
    built = subprocess.run([str(pinned), "build-commit"], env=env, cwd=base,
                           capture_output=True, text=True, check=True)
    source = built.stdout.strip()
    require(len(source) == 40 and all(c in "0123456789abcdef" for c in source), "binary has no exact embedded commit")
    identity = {"source": source, "sha256": binary_hash, "original_binary": str(binary),
                "copied_binary": str(pinned), "base": str(base), "port": port,
                "model_port": model.server_port, "environment_keys": sorted(env),
                "runner_sha256": digest(Path(__file__)), "runtime_fixture_sha256": digest(runtime_fixture),
                "sandbox_scope": "Explicit lazy microVM declaration, unexecuted fixture image pin; no daemon preflight disabled and no guest execution proven."}
    write_json(out / "identity.json", identity)
    process = None
    stop_samples = threading.Event()
    owner["stop_samples"] = stop_samples
    sampler = None
    samples = []
    phase = ["starting"]
    phase_events = []

    def record_phase_event(event):
        event["wall_time_ns"] = time.time_ns()
        phase_events.append(event)
        with (out / "workload-phases.jsonl").open("a") as stream:
            stream.write(json.dumps(event) + "\n")

    def change_phase(label):
        phase[0] = label
        record_phase_event({"phase": label, "started_ns": time.perf_counter_ns()})
    operations = []
    terminal = {}
    success = False
    try:
        with (out / "server.log").open("wb") as log:
            process = subprocess.Popen([str(pinned), "--host", "127.0.0.1", "--base-path", str(base),
                                        "--port", str(port)], env=env, cwd=base, stdout=log, stderr=log,
                                       start_new_session=True)
            owner["process"] = process
            write_json(out / "owned-process.json", {"pid": process.pid, "base": str(base),
                "source": source, "binary_sha256": binary_hash, "started_ns": time.perf_counter_ns()})
            anonymous = Client(port, None, out, args.request_timeout)

            def ready():
                try:
                    health, _ = anonymous.get("/health?full=1")
                    return health if health.get("startup", {}).get("state_ready") is True else None
                except (OSError, http.client.HTTPException):
                    return None

            before = wait_for("readiness", ready, process, args.settle_timeout)
            require(before["paths"]["effective_masc_root"] == str(base / ".masc")
                    and before["build"]["binary_commit"] == source
                    and before["build"]["executable_sha256"] == binary_hash
                    and before["keeper_fibers"] == 0, "runtime source or isolation mismatch")
            write_json(out / "health-before.json", before)
            token_result, _ = anonymous.get("/api/v1/dashboard/dev-token")
            require(isinstance(token_result.get("token"), str), "isolated token unavailable")
            client = Client(port, token_result["token"], out, args.request_timeout)
            client.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "keeper-scale-session", "version": "1"}}, "initialize")
            for name in names:
                client.tool("masc_keeper_up", {"name": name, "create_only": True,
                    "sandbox_profile": "microvm", "microvm_backend": "apple_container",
                    "sandbox_image": "base", "network_mode": "none", "skills": {"names": []},
                    "board_interests": [], "activation_mode": "on_demand",
                    "instructions": "Reply to each isolated workload input with its typed fixture result. Do not call tools."}, "create")

            def all_live():
                health, _ = client.get("/health?full=1")
                return health if health.get("keeper_fibers") == args.keepers else None

            resident = wait_for("all Keeper owners", all_live, process, args.settle_timeout)
            write_json(out / "health-resident.json", resident)

            def sample():
                probe = Client(port, token_result["token"], out, args.request_timeout)
                while not stop_samples.is_set():
                    label = phase[0]
                    try:
                        body, row = probe.get("/health/live")
                        row["valid"] = body.get("live") is True
                    except (OSError, http.client.HTTPException, ProbeError, ValueError) as error:
                        row = (getattr(error, "row", None) or {}).copy()
                        row.update(valid=False, error=type(error).__name__, detail=str(error))
                    row["workload_phase"] = label
                    samples.append(row)
                    stop_samples.wait(args.sample_interval)

            change_phase("submitting_model_held")
            sampler = threading.Thread(target=sample, daemon=True)
            owner["sampler"] = sampler
            sampler.start()
            for sequence in range(1, args.messages_per_keeper + 1):
                for name in names:
                    message = json.dumps({"schema": "masc.keeper-scale-input.v1", "marker": marker,
                                          "keeper": name, "sequence": sequence}, sort_keys=True)
                    accepted, row = client.tool("masc_keeper_msg", {"name": name, "message": message}, "enqueue")
                    require(isinstance(accepted.get("operation_id"), str), "enqueue omitted operation identity")
                    operations.append({"keeper": name, "sequence": sequence, "operation_id": accepted["operation_id"],
                                       "admission": accepted, "admission_wire_ms": row["wire_ms"],
                                       "first_attempt_to_accepted_ms": row["first_attempt_to_response_ms"]})
            write_json(out / "operations-admitted.json", operations)

            def all_model_started():
                with fixture.lock:
                    require(not fixture.errors, "scripted provider rejected a request; inspect model-outcomes.jsonl")
                    return {row["keeper"] for row in fixture.requests} == set(names)

            wait_for("actual model request from every Keeper", all_model_started, process, args.settle_timeout)
            change_phase("model_held_queue_observation")
            held, _ = client.get("/health?full=1")
            write_json(out / "health-model-held.json", held)

            def observe_operation(operation, label, deadline):
                while True:
                    require(process.poll() is None, "owned server exited during operation observation")
                    require(time.monotonic() < deadline,
                            "read-only operation observation deadline; owner still live")
                    try:
                        status, _ = client.tool("masc_keeper_delegate_status", {
                            "target": {"kind": "keeper", "name": operation["keeper"]},
                            "operation_id": operation["operation_id"]}, label)
                        return status
                    except (OSError, http.client.HTTPException) as error:
                        # This is a read of an exact already-admitted operation.
                        # A lost observation never says the owner/turn stopped.
                        observation = {"keeper": operation["keeper"],
                            "operation_id": operation["operation_id"], "phase": label,
                            "error": type(error).__name__, "detail": str(error),
                            "server_pid": process.pid, "server_returncode": process.poll(),
                            "runtime_instance_id": before["build"]["runtime_instance_id"],
                            "observed_at_ns": time.perf_counter_ns()}
                        with (out / "operation-observation-failures.jsonl").open("a") as log:
                            log.write(json.dumps(observation) + "\n")
                        require(process.poll() is None, "owned server exited after lost observation")
                        require(time.monotonic() < deadline,
                                "read-only operation observation deadline; owner still live")

            queue_before = []
            held_deadline = time.monotonic() + args.settle_timeout
            for operation in operations:
                status = observe_operation(operation, "queue-held", held_deadline)
                queue_before.append({"keeper": operation["keeper"], "sequence": operation["sequence"], "status": status})
                require(status.get("state") in ("Queued", "Running"), "operation settled before provider release")
            write_json(out / "queue-held.json", queue_before)
            with fixture.lock:
                require(fixture.active == args.keepers, "not every Keeper has an actual held provider request")
                record_phase_event({"event": "provider_release", "at_ns": time.perf_counter_ns(),
                                    "active_provider_requests": fixture.active})
            change_phase("running_model_released")
            fixture.release.set()
            pending = {operation["operation_id"]: operation for operation in operations}
            deadline = time.monotonic() + args.settle_timeout
            while pending:
                require(process.poll() is None, "owned server exited during workload")
                with fixture.lock:
                    require(not fixture.errors, "scripted provider failed; inspect model-outcomes.jsonl")
                for operation_id, operation in list(pending.items()):
                    status = observe_operation(operation, "settlement", deadline)
                    state = status.get("state")
                    if state in ("Succeeded", "Failed", "Cancelled"):
                        terminal[operation_id] = status
                        require(state == "Succeeded", "operation failed; inspect terminal.json/requests.jsonl")
                        replies = [obj for obj in objects(status.get("completed_reply"))
                                   if obj.get("schema") == "masc.keeper-scale-reply.v1"
                                   and obj.get("marker") == marker and obj.get("keeper") == operation["keeper"]
                                   and operation["sequence"] in obj.get("sequences", [])]
                        require(len(replies) == 1, "full completed reply does not cover its exact queued input")
                        pending.pop(operation_id)
                write_json(out / "terminal.json", terminal)
                require(not pending or time.monotonic() < deadline, "Keeper operation observation deadline")
                if pending:
                    time.sleep(.1)
            change_phase("settled")
            after, _ = client.get("/health?full=1")
            require(after["build"]["runtime_instance_id"] == before["build"]["runtime_instance_id"]
                    and after["keeper_fibers"] == args.keepers, "runtime identity or Keeper population changed")
            write_json(out / "health-after.json", after)
            coverage = defaultdict(list)
            with fixture.lock:
                for row in fixture.requests:
                    coverage[row["keeper"]].extend(row["sequences"])
                require(not fixture.errors, "provider error recorded")
            require(set(coverage) == set(names) and all(sorted(value) == list(range(1, args.messages_per_keeper+1))
                    for value in coverage.values()), "model request coverage is missing or duplicated")
            write_json(out / "model-coverage.json", {"actual_model_calls": len(fixture.requests),
                "max_provider_requests_in_flight": fixture.max_active, "per_keeper_sequences": coverage})
            shutil.copytree(config, out / "final-config")
            success = True
    finally:
        fixture.release.set()
        stop_samples.set()
        if sampler is not None:
            sampler.join(timeout=args.request_timeout + 1)
        write_json(out / "latency-samples.json", samples)
        write_json(out / "workload-phases.json", phase_events)
        write_json(out / "terminal.json", terminal)
        forced = False
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                forced = True
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        model.shutdown()
        model.server_close()
        model_thread.join(timeout=5)
        owner["model_stopped"] = not model_thread.is_alive()
        with fixture.lock:
            model_drained = fixture.active == 0 and fixture.handler_count == 0
        guest_commands = ([json.loads(line) for line in guard_log.read_text().splitlines()]
                          if guard_log.exists() else [])
        write_json(out / "guest-command-attempts.json", guest_commands)
        denied_inventory = [row for row in guest_commands if denied_inventory_kind(row, guard_dir, names)]
        unexpected_guest_commands = [row for row in guest_commands if row not in denied_inventory]
        write_json(out / "denied-inventory.json", denied_inventory)
        durable = []
        for database in sorted((base / ".masc").rglob("chat-operations.sqlite3")):
            connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
            connection.row_factory = sqlite3.Row
            try:
                rows = [dict(row) for row in connection.execute(
                    "SELECT operation_id, state, started_at, completed_at, outcome_ref, failure_kind FROM operations ORDER BY sequence")]
                target = out / "durable" / database.parent.name
                target.mkdir(parents=True, exist_ok=True)
                with sqlite3.connect(target / database.name) as backup:
                    connection.backup(backup)
                durable.append({"keeper": database.parent.name, "source_path": str(database), "rows": rows})
            finally:
                connection.close()
        write_json(out / "durable-operations.json", durable)
        cleanup = {"server_returncode": None if process is None else process.poll(),
                   "server_reaped": process is not None and process.poll() is not None,
                   "forced_kill": forced, "sampler_stopped": sampler is None or not sampler.is_alive(),
                   "model_server_stopped": not model_thread.is_alive(), "base_removed": False}
        cleanup.update(provider_requests_drained=model_drained,
                       active_provider_requests=fixture.active, provider_handler_threads=fixture.handler_count)
        shutil.rmtree(base)
        cleanup["base_removed"] = not base.exists()
        write_json(out / "cleanup.json", cleanup)
    require(success and not unexpected_guest_commands and model_drained
            and cleanup["server_returncode"] == 0 and not cleanup["forced_kill"]
            and cleanup["server_reaped"] and cleanup["model_server_stopped"] and cleanup["sampler_stopped"]
            and cleanup["base_removed"], "workload or owned cleanup incomplete")
    stored = {row["operation_id"]: row for item in durable for row in item["rows"]}
    require({item["keeper"] for item in durable} == set(names), "durable Keeper population differs")
    for item in durable:
        expected = {operation["operation_id"] for operation in operations if operation["keeper"] == item["keeper"]}
        require({row["operation_id"] for row in item["rows"]} == expected,
                "operation was persisted under a different Keeper target")
        require(all(row["outcome_ref"] == terminal[row["operation_id"]]["outcome_ref"]
                    for row in item["rows"]), "durable outcome differs from exact public operation")
    require(set(stored) == {operation["operation_id"] for operation in operations}
            and all(row["state"] == "succeeded" and row["outcome_ref"]
                    and row["started_at"] is not None and row["completed_at"] is not None
                    and row["failure_kind"] is None for row in stored.values()),
            "offline authoritative SQLite reread did not prove all exact operations succeeded")
    valid = sorted(row["wire_ms"] for row in samples if row.get("valid"))
    summary = {"keepers": args.keepers, "messages": len(operations), "succeeded_operations": len(stored),
               "actual_model_calls": len(fixture.requests), "max_provider_requests_in_flight": fixture.max_active,
               "latency_samples": len(samples), "valid_latency_samples": len(valid),
               "scope": "Installed-source real Keeper turns with a loopback scripted text-only model, durable queued operations and offline SQLite reread. No guest/tool execution, browser/TUI or production throughput proof."}
    summary["latency_by_phase"] = {}
    for label in dict.fromkeys(row["workload_phase"] for row in samples):
        selected = [row for row in samples if row["workload_phase"] == label]
        elapsed = sorted(row["wire_ms"] for row in selected if row.get("valid"))
        summary["latency_by_phase"][label] = {"samples": len(selected), "valid": len(elapsed),
            "failures": len(selected)-len(elapsed),
            "p50_ms": elapsed[math.ceil(.5*len(elapsed))-1] if elapsed else None,
            "p95_ms": elapsed[math.ceil(.95*len(elapsed))-1] if elapsed else None,
            "max_ms": max(elapsed) if elapsed else None}
    waits = ([json.loads(line) for line in (out / "rate-limit-waits.jsonl").read_text().splitlines()]
             if (out / "rate-limit-waits.jsonl").exists() else [])
    summary.update(rejected_429_count=len(waits),
                   rate_limit_wait_s=sum((row["wait_finished_ns"]-row["wait_started_ns"])/1e9 for row in waits),
                   rate_limit_wait_by_source_s={source: sum(
                       (row["wait_finished_ns"]-row["wait_started_ns"])/1e9
                       for row in waits if row["source"] == source)
                       for source in dict.fromkeys(row["source"] for row in waits)},
                   denied_read_only_inventory_attempts=len(denied_inventory),
                   unexpected_guest_command_attempts=len(unexpected_guest_commands))
    write_json(out / "summary.json", summary)
    print(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--keepers", type=int, default=2)
    parser.add_argument("--messages-per-keeper", type=int, default=2)
    parser.add_argument("--model-delay-ms", type=float, default=10)
    parser.add_argument("--sample-interval", type=float, default=.1)
    parser.add_argument("--request-timeout", type=float, default=15)
    parser.add_argument("--settle-timeout", type=float, default=120)
    args = parser.parse_args()
    require(all(math.isfinite(value) for value in (args.model_delay_ms, args.sample_interval,
                args.request_timeout, args.settle_timeout))
            and args.keepers > 0 and args.messages_per_keeper > 0 and args.model_delay_ms >= 0
            and args.sample_interval > 0 and args.request_timeout > 0 and args.settle_timeout > 0,
            "workload sizes and observation durations must be positive")
    owner = {}
    try:
        run(args, owner)
    except BaseException as error:
        # This also owns failures before the server's main try/finally (for
        # example fixture/config validation), and failures copying a damaged
        # store. Never leave a server or model listener behind on those paths.
        if "fixture" in owner:
            owner["fixture"].release.set()
        if "stop_samples" in owner:
            owner["stop_samples"].set()
        if "sampler" in owner:
            owner["sampler"].join(timeout=args.request_timeout + 1)
        process = owner.get("process")
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        model = owner.get("model")
        thread = owner.get("model_thread")
        if model is not None:
            if thread is not None and thread.is_alive():
                model.shutdown()
                thread.join(timeout=5)
            model.server_close()
        base = owner.get("base")
        if base is not None and base.exists():
            shutil.rmtree(base)
        if args.output.is_dir():
            if not (args.output / "cleanup.json").exists():
                write_json(args.output / "cleanup.json", {"fallback_cleanup": True,
                    "server_reaped": process is None or process.poll() is not None,
                    "server_returncode": None if process is None else process.poll(),
                    "model_server_stopped": thread is None or not thread.is_alive(),
                    "base_removed": base is None or not base.exists()})
            write_json(args.output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
