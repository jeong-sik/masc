"""Does --publish-socket reach a guest with --network none, and does its relay leak?

One scratch container per network mode, keeper image, guest python listener.
Per mode: 100 request/response round trips (2 KiB up, count back), 30 with a
70,000-byte reply (length checked), 10 abandoned connections (closed without a
reply read; guest must still see EOF), then 20 `container exec -i` calls as the
positive leak control. Orphan pipe fds of the guest's runtime are read around
each phase.
"""

import json
import os
import socket
import statistics
import subprocess
import time

CONTAINER = "/opt/homebrew/bin/container"
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "kit")
SOCK_DIR = os.path.expanduser("~/me/workspace/yousleepwhen/masc/.tmp/sp")
BIG = 70000
LSOF_COLUMNS_ORPHAN = 7


def runtime_pid(name):
    listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True).stdout
    for line in listing.splitlines():
        if "container-runtime-linux start" in line and f"--uuid {name}" in line:
            return int(line.split()[0])
    raise RuntimeError("runtime pid not found")


def orphans(pid):
    listing = subprocess.run(["lsof", "-n", "-w", "-p", str(pid)], capture_output=True, text=True).stdout
    return sum(1 for line in listing.splitlines()[1:]
               if len(line.split()) == LSOF_COLUMNS_ORPHAN and line.split()[4] == "PIPE")


def round_trip(path, payload):
    start = time.monotonic()
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(20)
    client.connect(path)
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    reply = b""
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        reply += chunk
    client.close()
    return time.monotonic() - start, reply


def stats(lat):
    ordered = sorted(lat)
    return {"n": len(lat), "p50_ms": round(statistics.median(lat) * 1000),
            "p90_ms": round(ordered[int(len(ordered) * 0.9) - 1] * 1000), "max_ms": round(max(lat) * 1000)}


def run_mode(mode):
    name = f"masc-sockprobe-{mode}"
    host_sock = os.path.join(SOCK_DIR, f"{mode}.sock")
    for leftover in (host_sock,):
        if os.path.exists(leftover):
            os.remove(leftover)
    subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
    network = ["--network", "none"] if mode == "none" else []
    started = subprocess.run([CONTAINER, "run", "-d", "--name", name, "-m", "1G", "-c", "1", "--user", "502:20",
                              *network, "-v", f"{KIT}:/opt/probe:ro",
                              "--publish-socket", f"{host_sock}:/tmp/probe.sock",
                              "--entrypoint", "python3", IMAGE, "/opt/probe/sockserver.py"],
                             capture_output=True, text=True)
    result = {"mode": mode, "run_rc": started.returncode, "run_err": started.stderr.strip()[-200:]}
    try:
        if started.returncode != 0:
            return result
        deadline = time.monotonic() + 60
        ready_error = None
        while time.monotonic() < deadline:
            try:
                round_trip(host_sock, b"ping")
                ready_error = None
                break
            except OSError as error:
                ready_error = repr(error)
                time.sleep(2)
        if ready_error:
            result["ready_error"] = ready_error
            return result
        pid = runtime_pid(name)
        result["orphans_ready"] = orphans(pid)
        payload = os.urandom(2048)
        lat, wrong = [], 0
        for _ in range(100):
            seconds, reply = round_trip(host_sock, payload)
            lat.append(seconds)
            wrong += reply != b"2048"
        result["small"] = {**stats(lat), "wrong_replies": wrong, "orphans_after": orphans(pid)}
        lat, short = [], 0
        for _ in range(30):
            seconds, reply = round_trip(host_sock, b"B" + payload)
            lat.append(seconds)
            short += len(reply) != BIG
        result["big_reply"] = {**stats(lat), "wrong_length": short, "orphans_after": orphans(pid)}
        before_marks = subprocess.run([CONTAINER, "exec", name, "sh", "-c", "wc -c < /tmp/eof.count"],
                                      capture_output=True, text=True).stdout.strip()
        for _ in range(10):
            client = socket.socket(socket.AF_UNIX)
            client.connect(host_sock)
            client.sendall(b"partial")
            time.sleep(0.3)
            client.close()
        time.sleep(2)
        after_marks = subprocess.run([CONTAINER, "exec", name, "sh", "-c", "wc -c < /tmp/eof.count"],
                                     capture_output=True, text=True).stdout.strip()
        result["abandoned"] = {"calls": 10, "guest_eof_before": before_marks, "guest_eof_after": after_marks,
                               "orphans_after": orphans(pid)}
        before = orphans(pid)
        for _ in range(20):
            subprocess.run([CONTAINER, "exec", "-i", name, "true"], stdin=subprocess.DEVNULL, capture_output=True)
        result["exec_i_control"] = {"calls": 20, "orphan_delta": orphans(pid) - before}
        return result
    finally:
        subprocess.run([CONTAINER, "stop", name], capture_output=True)
        subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
        if os.path.exists(host_sock):
            os.remove(host_sock)
        print(json.dumps(result), flush=True)


def main():
    os.makedirs(SOCK_DIR, exist_ok=True)
    run_mode("none")
    run_mode("inherit")


if __name__ == "__main__":
    main()
