#!/usr/bin/env python3
"""Exercise cleanup and lease contention in isolated stdio and HTTP owners."""

import hashlib
import http.client
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


repo = Path(os.environ["DUNE_SOURCEROOT"])
http_binary, stdio_binary = (Path(arg).resolve() for arg in sys.argv[1:3])
os.umask(0o077)


def orphan(base, value):
    contents = json.dumps(value, separators=(",", ":")).encode()
    scope = hashlib.sha256(b"startup-fixture").hexdigest()
    digest = hashlib.sha256(contents).hexdigest()
    path = base / ".masc/lane-addons/tool-request-bodies" / scope / (digest + ".json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(contents)
    return path


def initialize(process, log):
    request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "orphan-startup-fixture", "version": "1"}}}
    process.stdin.write((json.dumps(request) + "\n").encode())
    process.stdin.flush()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if selector.select(0.2):
                line = process.stdout.readline()
                if not line:
                    raise AssertionError("stdio closed: " + log.read_text()[-3000:])
                response = json.loads(line)
                if response.get("id") == 1:
                    assert "result" in response, response
                    return
        raise AssertionError("stdio did not initialize: " + log.read_text()[-3000:])


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix="masc-orphan-startup-") as tmp:
    base = Path(tmp)
    cfg = base / ".masc/config"
    cfg.mkdir(parents=True)
    (cfg / "keepers").mkdir()
    shutil.copytree(repo / "config/prompts", cfg / "prompts")
    (cfg / "runtime.toml").write_text(
        '[providers.ollama]\nprotocol="ollama-http"\nendpoint="http://127.0.0.1:9"\n'
        '[models.fixture]\napi-name="hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL"\n'
        'max-context=1024\n[ollama.fixture]\n[runtime]\ndefault="ollama.fixture"\n')
    auth = base / ".masc/auth"
    auth.mkdir()
    (auth / "config.json").write_text(json.dumps({"enabled": False, "workspace_secret_hash": None,
        "require_token": False, "token_expiry_hours": 24}))
    leases = base / "leases"
    leases.mkdir(mode=0o700)
    env = {"PATH": os.environ["PATH"], "HOME": tmp, "DUNE_SOURCEROOT": str(repo),
           "MASC_BASE_PATH_LEASE_DIR": str(leases), "MASC_CONFIG_BOOTSTRAP": "skip",
           "MASC_KEEPER_AUTONOMOUS_ENABLED": "false"}

    first = orphan(base, "before-stdio")
    stdio_log = base / "stdio.log"
    with stdio_log.open("wb") as log:
        process = subprocess.Popen([str(stdio_binary), "--base-path", tmp],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, env=env, cwd=repo)
        try:
            initialize(process, stdio_log)
            assert not first.exists(), "stdio initialized without collecting its startup orphan"
            second = orphan(base, "while-stdio-owns-base")
            contender = subprocess.run([str(stdio_binary), "--base-path", tmp],
                stdin=subprocess.DEVNULL, capture_output=True, env=env, cwd=repo, timeout=30)
            assert contender.returncode != 0, "another stdio owner acquired the same lease"
            assert b"stdio runtime cannot start" in contender.stdout + contender.stderr, contender.stderr
            assert second.exists(), "lease-rejected process touched the active owner's body"
        finally:
            stop(process)

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    server_log = base / "http.log"
    with server_log.open("wb") as log:
        server = subprocess.Popen([str(http_binary), "start", "--base-path", tmp,
            "--host", "127.0.0.1", "--port", str(port)], env=env, cwd=repo,
            stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while True:
                assert server.poll() is None, "HTTP owner exited: " + server_log.read_text()[-3000:]
                try:
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                    try:
                        connection.request("GET", "/health?full=1")
                        response = connection.getresponse()
                        health = json.loads(response.read()) if response.status == 200 else {}
                    finally:
                        connection.close()
                    if health.get("startup", {}).get("state_ready"):
                        break
                except (http.client.HTTPException, TimeoutError, OSError):
                    pass
                assert time.monotonic() < deadline, "HTTP owner not ready: " + server_log.read_text()[-3000:]
                time.sleep(0.1)
            assert not second.exists(), "HTTP initialized without collecting its startup orphan"
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait(timeout=5)

print("isolated stdio and HTTP orphan startup: PASS")
