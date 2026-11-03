"""Which Keeper run flag stops --publish-socket from reaching the guest listener?

Each variant starts the keeper image with kit/agent_probe.py, sends one
length-prefixed request (write side half-closed, then held open in a second
try), and reads the agent's connection log. Results: relay-flags-results.json.
"""

import json
import os
import socket
import struct
import subprocess
import time

CONTAINER = "/opt/homebrew/bin/container"
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "kit")
OUT = os.path.join(ROOT, "relay-flags-results.json")
SOCK_DIR = os.path.expanduser("~/me/workspace/yousleepwhen/masc/.tmp/sa")
KEEPER_USER = ["--user", "502:20"]
ROOT_DROP = ["--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID"]
VARIANTS = [
    ("plain_subdir", KEEPER_USER, "/tmp/masc-agent/agent.sock", "same-uid"),
    ("tmpfs_tmp", KEEPER_USER + ["--tmpfs", "/tmp"], "/tmp/masc-agent/agent.sock", "same-uid"),
    ("capdrop_rm", KEEPER_USER + ["--cap-drop", "ALL", "--rm"], "/tmp/masc-agent/agent.sock", "same-uid"),
    ("readonly_tmpfs_flat", KEEPER_USER + ["--read-only", "--tmpfs", "/tmp"], "/tmp/agent.sock", "same-uid"),
    ("root_drop_rootfs", ROOT_DROP + ["--cap-drop", "ALL", "--rm"], "/run/masc-agent/agent.sock", "root-drop"),
    ("root_drop_tmpfs_run", ROOT_DROP + ["--cap-drop", "ALL", "--rm", "--tmpfs", "/run"],
     "/run/masc-agent/agent.sock", "root-drop"),
]


def ask(path, half_close):
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(8)
    client.connect(path)
    client.sendall(struct.pack(">I", 4) + b"ping")
    if half_close:
        client.shutdown(socket.SHUT_WR)
    data = b""
    try:
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        data += b"<timeout>"
    client.close()
    return data[4:].decode(errors="replace") if len(data) > 4 else repr(data)


def main():
    os.makedirs(SOCK_DIR, exist_ok=True)
    results = []
    for label, flags, guest_sock, mode in VARIANTS:
        name = f"masc-relayprobe-{label.replace('_', '-')}"
        host_sock = os.path.join(SOCK_DIR, f"{label[:12]}.sock")
        if os.path.exists(host_sock):
            os.remove(host_sock)
        subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
        started = subprocess.run([CONTAINER, "run", "-d", "--name", name, "-m", "1G", "-c", "1", *flags,
                                  "-v", f"{KIT}:/opt/probe:ro", "--publish-socket", f"{host_sock}:{guest_sock}",
                                  "--entrypoint", "python3", IMAGE, "/opt/probe/agent_probe.py", guest_sock, mode],
                                 capture_output=True, text=True)
        result = {"variant": label, "flags": flags, "guest_sock": guest_sock, "run_rc": started.returncode}
        try:
            if started.returncode != 0:
                result["run_err"] = started.stderr.strip()[-300:]
                continue
            time.sleep(4)
            for key, half in (("half_close", True), ("held_open", False)):
                try:
                    result[key] = ask(host_sock, half)
                except OSError as error:
                    result[key] = repr(error)
            for path, key in (("/tmp/agent-status.json", "agent_status"), ("/tmp/agent-conn.log", "agent_log")):
                read = subprocess.run([CONTAINER, "exec", name, "cat", path], capture_output=True, text=True,
                                      stdin=subprocess.DEVNULL)
                result[key] = (read.stdout or read.stderr).strip()[-400:]
        finally:
            subprocess.run([CONTAINER, "stop", name], capture_output=True)
            subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
            if os.path.exists(host_sock):
                os.remove(host_sock)
            results.append(result)
            print(json.dumps(result), flush=True)
    with open(OUT, "w") as handle:
        json.dump(results, handle, indent=2)


if __name__ == "__main__":
    main()
