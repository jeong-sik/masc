"""A resident agent behind --publish-socket, under the Keeper VM run flags.

Cases (keeper image, --read-only, --tmpfs /tmp, --cap-drop ALL, --rm):
  naive      : agent runs as 502:20, socket under /tmp (Keeper-writable).
  root_drop  : agent starts as root with only SETUID/SETGID added, socket in a
               root-only directory on a /run tmpfs, then drops to 502:20.
  root_drop_init : root_drop plus --init, to read what inspect reports.
Per case: agent status, 100 sequential requests (write side held open),
20 concurrent requests, one request idle 60 s, a hijack attempt by the Keeper
uid through `container exec -d` (no -i), and `container inspect` facts.
Pipe and total fd counts of the guest runtime are read around the requests.
Raw results go to agent-shape-results.json next to this directory.
"""

import json
import os
import socket
import statistics
import struct
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

CONTAINER = "/opt/homebrew/bin/container"
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "kit")
OUT = os.path.join(ROOT, "agent-shape-results.json")
# macOS limits a unix socket path to 104 bytes; the scratch root is longer.
SOCK_DIR = os.path.expanduser("~/me/workspace/yousleepwhen/masc/.tmp/sa")
LSOF_COLUMNS_ORPHAN = 7
KEEPER_FLAGS = ["--read-only", "--tmpfs", "/tmp", "--cap-drop", "ALL", "--rm",
                "-m", "1G", "-c", "1", "-v", f"{KIT}:/opt/probe:ro"]
CASES = {
    "naive": {"user": ["--user", "502:20"], "extra": [], "guest_sock": "/tmp/masc-agent/agent.sock",
              "mode": "same-uid"},
    "root_drop": {"user": [], "extra": ["--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
                                        "--tmpfs", "/run"],
                  "guest_sock": "/run/masc-agent/agent.sock", "mode": "root-drop"},
    "root_drop_init": {"user": [], "extra": ["--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
                                             "--tmpfs", "/run", "--init"],
                       "guest_sock": "/run/masc-agent/agent.sock", "mode": "root-drop"},
}


def runtime_pid(name):
    listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True).stdout
    for line in listing.splitlines():
        if "container-runtime-linux start" in line and f"--uuid {name}" in line:
            return int(line.split()[0])
    return None


def fd_counts(pid):
    listing = subprocess.run(["lsof", "-n", "-w", "-p", str(pid)], capture_output=True, text=True).stdout
    rows = listing.splitlines()[1:]
    orphan = sum(1 for line in rows if len(line.split()) == LSOF_COLUMNS_ORPHAN and line.split()[4] == "PIPE")
    return {"orphan_pipes": orphan, "all_fds": len(rows)}


def request(path, body, timeout=90):
    start = time.monotonic()
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(timeout)
    client.connect(path)
    client.sendall(struct.pack(">I", len(body)) + body)
    header = b""
    while len(header) < 4:
        chunk = client.recv(4 - len(header))
        if not chunk:
            raise EOFError("closed before reply")
        header += chunk
    size = struct.unpack(">I", header)[0]
    reply = b""
    while len(reply) < size:
        chunk = client.recv(size - len(reply))
        if not chunk:
            raise EOFError("short reply")
        reply += chunk
    client.close()
    return time.monotonic() - start, json.loads(reply)


def exec_plain(name, *argv, user=None, detach=False):
    command = [CONTAINER, "exec"] + (["-d"] if detach else []) + (["--user", user] if user else []) + [name, *argv]
    return subprocess.run(command, capture_output=True, text=True, stdin=subprocess.DEVNULL)


def run_case(label, case):
    name = f"masc-agentprobe-{label.replace('_', '-')}"
    host_sock = os.path.join(SOCK_DIR, f"{label}.sock")
    if os.path.exists(host_sock):
        os.remove(host_sock)
    subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
    argv = [CONTAINER, "run", "-d", "--name", name, *KEEPER_FLAGS, *case["user"], *case["extra"],
            "--publish-socket", f"{host_sock}:{case['guest_sock']}",
            "--entrypoint", "python3", IMAGE, "/opt/probe/agent_probe.py", case["guest_sock"], case["mode"]]
    started = subprocess.run(argv, capture_output=True, text=True)
    result = {"case": label, "run_rc": started.returncode, "run_err": started.stderr.strip()[-300:]}
    try:
        if started.returncode != 0:
            return result
        deadline = time.monotonic() + 60
        ready = None
        while time.monotonic() < deadline:
            try:
                request(host_sock, b"ping", timeout=5)
                ready = True
                break
            except (OSError, EOFError) as error:
                ready = repr(error)
                time.sleep(2)
        result["ready"] = ready
        if ready is not True:
            logs = subprocess.run([CONTAINER, "logs", name], capture_output=True, text=True)
            result["guest_log_tail"] = (logs.stdout + logs.stderr).strip()[-600:]
        status = exec_plain(name, "cat", "/tmp/agent-status.json")
        result["agent_status"] = status.stdout.strip() or status.stderr.strip()[-200:]
        inspect = subprocess.run([CONTAINER, "inspect", name], capture_output=True, text=True)
        try:
            config = json.loads(inspect.stdout)[0]["configuration"]
            result["inspect_init"] = [config["initProcess"]["executable"], *config["initProcess"]["arguments"]]
            result["inspect_user"] = config["initProcess"].get("user")
            result["inspect_published_sockets"] = config.get("publishedSockets")
            result["inspect_has_init_field"] = {key: config[key] for key in config if "init" in key.lower() and key != "initProcess"}
        except (ValueError, KeyError, IndexError) as error:
            result["inspect_error"] = repr(error)
        if ready is not True:
            return result
        pid = runtime_pid(name)
        result["fds_ready"] = fd_counts(pid)
        lat, wrong = [], 0
        for _ in range(100):
            seconds, reply = request(host_sock, os.urandom(2048))
            lat.append(seconds)
            wrong += reply.get("agent") != "genuine" or reply.get("size") != 2048
        result["sequential"] = {"n": 100, "wrong": wrong, "p50_ms": round(statistics.median(lat) * 1000, 1),
                                "max_ms": round(max(lat) * 1000, 1)}
        with ThreadPoolExecutor(max_workers=20) as pool:
            outcomes = list(pool.map(lambda _: request(host_sock, b"x" * 512), range(20)))
        result["concurrent"] = {"n": 20, "wrong": sum(1 for _, reply in outcomes if reply.get("agent") != "genuine"),
                                "max_ms": round(max(seconds for seconds, _ in outcomes) * 1000, 1)}
        seconds, reply = request(host_sock, b"sleep:60", timeout=90)
        result["idle_60s"] = {"seconds": round(seconds, 1), "agent": reply.get("agent")}
        result["fds_after_requests"] = fd_counts(pid)
        hijack = exec_plain(name, "python3", "/opt/probe/hijack.py", case["guest_sock"], user="502:20", detach=True)
        result["hijack_exec_rc"] = hijack.returncode
        time.sleep(3)
        hijack_status = exec_plain(name, "cat", "/tmp/hijack-status.json")
        result["hijack_status"] = hijack_status.stdout.strip() or hijack_status.stderr.strip()[-200:]
        try:
            _, reply = request(host_sock, b"after-hijack", timeout=10)
            result["after_hijack_reply"] = reply.get("agent")
        except (OSError, EOFError) as error:
            result["after_hijack_reply"] = repr(error)
        return result
    finally:
        subprocess.run([CONTAINER, "stop", name], capture_output=True)
        subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
        if os.path.exists(host_sock):
            os.remove(host_sock)
        print(json.dumps(result), flush=True)


def main():
    os.makedirs(SOCK_DIR, exist_ok=True)
    results = {"started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "cases": []}
    for label, case in CASES.items():
        results["cases"].append(run_case(label, case))
    with open(OUT, "w") as handle:
        json.dump(results, handle, indent=2)


if __name__ == "__main__":
    main()
