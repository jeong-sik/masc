"""Boot the argv that masc's own renderer produces for an agent plan, talk to
the agent, keep the runtime's inspect, and judge it with masc's own parser and
assessment. The renderer, parser and assessment are the harness that
agent_plan_harness.sh cuts verbatim from the repository.

Then the same judgement on a copy whose host paths and plan label are those of
the same plan with neutral host paths, and whose volume image paths (the
runtime's own, not compared) are neutral too. That copy is the test fixture
test/fixtures/apple-container-1.6.1-agent-guest-inspect.json.

argv: <harness> <stage dir> <socket dir> <out dir>
The stage dir holds out/masc-exec-shim and out/masc-exec-shim.conf, as
agent_l3.py builds them. The socket dir must be a short local path.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import time
import base64
from typing import Any

HARNESS, STAGE, SOCKET_DIR, OUT = sys.argv[1:5]
NAME = "fixture-agent"
VOLUMES = ["fixture-agent-work", "fixture-agent-build"]
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
NEUTRAL = {"socket": "/host/masc/agents/fixture-agent.sock",
           "identity": "/host/masc/identity/fixture-agent",
           "shim": "/host/masc/shim"}
HELLO_WAIT_SEC, READY_WAIT_SEC = 1.0, 60.0
KIND_HELLO, KIND_STDOUT, KIND_STDERR, KIND_EXIT = 1, 2, 3, 4


def sh(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True)


def harness(*args: str) -> str:
    done = sh([HARNESS, *args])
    if done.returncode != 0:
        raise RuntimeError(f"harness {args[0]}: {done.stderr}")
    return done.stdout


def recv_exact(conn: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        piece = conn.recv(size - len(data))
        if not piece:
            raise EOFError("short read")
        data += piece
    return data


def read_chunk(conn: socket.socket) -> tuple[int, bytes] | None:
    header = conn.recv(1)
    if not header:
        return None
    (length,) = struct.unpack(">I", recv_exact(conn, 4))
    return header[0], recv_exact(conn, length)


def connect_until_hello(path: str) -> tuple[socket.socket, dict[str, Any], int]:
    end, attempts = time.time() + READY_WAIT_SEC, 0
    while True:
        attempts += 1
        conn = socket.socket(socket.AF_UNIX)
        try:
            conn.settimeout(HELLO_WAIT_SEC)
            conn.connect(path)
            chunk = read_chunk(conn)
            if chunk is None or chunk[0] != KIND_HELLO:
                raise EOFError("no hello")
            conn.settimeout(30.0)
            return conn, json.loads(chunk[1]), attempts
        except (OSError, EOFError):
            conn.close()
            if time.time() > end:
                raise
            time.sleep(0.05)


def read_rest(conn: socket.socket) -> tuple[bytes, bytes, list[dict[str, int]]]:
    out, err, exits = b"", b"", []
    while (chunk := read_chunk(conn)) is not None:
        kind, payload = chunk
        if kind == KIND_STDOUT:
            out += payload
        elif kind == KIND_STDERR:
            err += payload
        elif kind == KIND_EXIT:
            exits.append({"exited" if payload[0] == 0 else "signaled": struct.unpack(">i", payload[1:5])[0]})
    return out, err, exits


def request_frame(argv: list[str]) -> bytes:
    def b64(text: str) -> str:
        return base64.b64encode(text.encode()).decode()

    body = json.dumps({"v": 3, "argv": [b64(a) for a in argv], "env": [], "cwd": b64("/masc-work"),
                       "remote_root": b64("/masc-work"), "timeout_sec": 30.0, "stdin_len": 0,
                       "mode": "effect", "acceptance_frame": True}).encode()
    return b"R" + struct.pack(">Q", len(body)) + body


def replace_strings(value: Any, mapping: dict[str, str]) -> Any:
    if isinstance(value, str):
        return mapping.get(value, value)
    if isinstance(value, list):
        return [replace_strings(item, mapping) for item in value]
    if isinstance(value, dict):
        return {key: replace_strings(item, mapping) for key, item in value.items()}
    return value


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    real = {"socket": os.path.join(SOCKET_DIR, "agent.sock"),
            "identity": os.path.join(SOCKET_DIR, "identity"),
            "shim": os.path.join(STAGE, "out")}
    os.makedirs(real["identity"], exist_ok=True)
    if os.path.lexists(real["socket"]):
        os.unlink(real["socket"])
    argv = json.loads(harness("render", NAME, real["socket"], real["identity"], real["shim"]))
    neutral_argv = json.loads(harness("render", NAME, NEUTRAL["socket"], NEUTRAL["identity"], NEUTRAL["shim"]))
    results: dict[str, Any] = {"container_version": sh(["container", "--version"]).stdout.strip(),
                               "argv": argv, "neutral_argv": neutral_argv}
    for volume in VOLUMES:
        results.setdefault("volume_create_rc", []).append(sh(["container", "volume", "create", volume]).returncode)
    try:
        ran = sh(argv)
        results["run_rc"] = ran.returncode
        if ran.returncode != 0:
            results["run_stderr"] = ran.stderr[-800:]
            return
        conn, hello, attempts = connect_until_hello(real["socket"])
        conn.close()
        results["hello"], results["hello_attempts"] = hello, attempts
        conn, _, _ = connect_until_hello(real["socket"])
        conn.sendall(b"P")
        out, _, exits = read_rest(conn)
        conn.close()
        probe = json.loads(out)
        results["probe"] = {"version": probe.get("version"), "capabilities": probe.get("capabilities"),
                            "exits": exits}
        conn, _, _ = connect_until_hello(real["socket"])
        conn.sendall(request_frame(["sh", "-c", "echo id=$(id -u):$(id -g); exit 5"]))
        out, err, exits = read_rest(conn)
        conn.close()
        results["request"] = {"stdout": out.decode(), "exits": exits, "stderr_tail": err.decode()[-300:]}
        inspect = sh(["container", "inspect", NAME]).stdout
        image_inspect = sh(["container", "image", "inspect", IMAGE]).stdout
    finally:
        results["stop_rc"] = sh(["container", "stop", NAME]).returncode
        for _ in range(60):
            if sh(["container", "inspect", NAME]).stdout.strip() in ("", "[]"):
                break
            time.sleep(0.5)
        results["socket_left"] = os.path.lexists(real["socket"])
        for volume in VOLUMES:
            results.setdefault("volume_delete_rc", []).append(sh(["container", "volume", "delete", volume]).returncode)
        with open(os.path.join(OUT, "boot.json"), "w") as f:
            json.dump(results, f, indent=1)
    paths = {"inspect": os.path.join(OUT, "inspect.json"), "image": os.path.join(OUT, "image-inspect.json"),
             "neutral": os.path.join(OUT, "agent-guest-inspect.json")}
    with open(paths["inspect"], "w") as f:
        f.write(inspect)
    with open(paths["image"], "w") as f:
        f.write(image_inspect)
    real_digest = harness("digest", real["socket"], real["identity"], real["shim"])
    neutral_digest = harness("digest", NEUTRAL["socket"], NEUTRAL["identity"], NEUTRAL["shim"])
    mapping = {real[key]: NEUTRAL[key] for key in real} | {real_digest: neutral_digest}
    neutral = replace_strings(json.loads(inspect), mapping)
    volumes = os.path.expanduser("~/Library/Application Support/com.apple.container/volumes/")
    for mount in neutral[0]["configuration"]["mounts"]:
        if "volume" in mount["type"] and mount["source"].startswith(volumes):
            mount["source"] = "/runtime/volumes/" + mount["source"][len(volumes):]
    with open(paths["neutral"], "w") as f:
        f.write(json.dumps(neutral, indent=1) + "\n")
    results["digests"] = {"real_paths": real_digest, "neutral_paths": neutral_digest}
    results["assess_real_paths"] = harness("assess", NAME, real["socket"], real["identity"], real["shim"],
                                           paths["inspect"], paths["image"]).splitlines()
    results["assess_fixture"] = harness("assess", NAME, NEUTRAL["socket"], NEUTRAL["identity"], NEUTRAL["shim"],
                                        paths["neutral"], paths["image"]).splitlines()
    with open(os.path.join(OUT, "agent-plan-boot-results.json"), "w") as f:
        json.dump(results, f, indent=1)
    print("argv tokens", len(argv), "run_rc", results["run_rc"], "hello", results["hello"],
          "attempts", results["hello_attempts"])
    print("probe", results["probe"])
    print("request", results["request"]["stdout"].strip(), results["request"]["exits"])
    print("stop", results["stop_rc"], "socket_left", results["socket_left"],
          "volumes", results.get("volume_create_rc"), results.get("volume_delete_rc"))
    print("real paths:", results["assess_real_paths"])
    print("fixture:", results["assess_fixture"])


if __name__ == "__main__":
    main()
