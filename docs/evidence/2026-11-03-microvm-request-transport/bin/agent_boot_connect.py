"""What a host connection made the moment an agent VM is up receives.

argv: <stage dir from agent_l3.py> <host socket path> <results json> [boots]

Each boot starts the agent VM the way agent_l3.py does, connects as soon as
`container run -d` returns, and waits up to WAIT_SEC for the first byte or
the end of the stream. Then a fresh connection checks the agent answers, and
the VM is stopped.
"""

import json
import os
import socket
import subprocess
import sys
import time

STAGE, HOST_SOCKET, RESULTS = sys.argv[1:4]
BOOTS = int(sys.argv[4]) if len(sys.argv) > 4 else 5
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
GUEST_SOCKET = "/run/masc-agent/agent.sock"
SHIM_DIR = "/opt/masc-exec-shim"
WORK = "/masc-work"
WAIT_SEC = 30.0
LATER_WAIT_SEC = 5.0
RUN_FLAGS = [
    "--cap-drop", "ALL", "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
    "--cap-add", "CAP_SYS_ADMIN", "--tmpfs", "/tmp", "-m", "1G", "-c", "1",
]


def sh(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True)


def first_event(conn: socket.socket, wait: float) -> tuple[str, float]:
    started = time.time()
    conn.settimeout(wait)
    try:
        byte = conn.recv(1)
        return ("eof" if byte == b"" else "hello" if byte == b"\x01" else f"byte {byte!r}",
                round(time.time() - started, 3))
    except socket.timeout:
        return "nothing", round(time.time() - started, 3)
    except OSError as error:
        return f"error {error.strerror}", round(time.time() - started, 3)


def boot(index: int) -> dict[str, object]:
    name = f"masc-agent-boot-{int(time.time())}-{index}"
    if os.path.exists(HOST_SOCKET):
        os.unlink(HOST_SOCKET)
    run = sh(["container", "run", "-d", "--rm", "--name", name, *RUN_FLAGS,
              "-v", f"{os.path.join(STAGE, 'out')}:{SHIM_DIR}:ro",
              "-v", f"{os.path.join(STAGE, 'work')}:{WORK}", "-w", WORK,
              "--env", "HOME=/tmp", "--env", f"MASC_EXEC_SHIM_CONFIG={SHIM_DIR}/masc-exec-shim.conf",
              "--publish-socket", f"{HOST_SOCKET}:{GUEST_SOCKET}",
              IMAGE, f"{SHIM_DIR}/masc-exec-shim", "--serve", GUEST_SOCKET, "502:20"])
    record: dict[str, object] = {"name": name, "run_rc": run.returncode}
    returned = time.time()
    early = socket.socket(socket.AF_UNIX)
    try:
        early.connect(HOST_SOCKET)
        record["connect_after_run_ms"] = round((time.time() - returned) * 1000)
        record["early"], record["early_seconds"] = first_event(early, WAIT_SEC)
    except OSError as error:
        record["early"] = f"connect error {error.strerror}"
    finally:
        early.close()
    later = socket.socket(socket.AF_UNIX)
    try:
        later.connect(HOST_SOCKET)
        record["later"], record["later_seconds"] = first_event(later, LATER_WAIT_SEC)
    except OSError as error:
        record["later"] = f"connect error {error.strerror}"
    finally:
        later.close()
    record["stop_rc"] = sh(["container", "stop", name]).returncode
    return record


def main() -> None:
    results: dict[str, object] = {
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "container_version": sh(["container", "--version"]).stdout.strip(),
        "wait_sec": WAIT_SEC,
        "boots": [boot(index) for index in range(BOOTS)],
    }
    with open(RESULTS, "w") as f:
        json.dump(results, f, indent=1)
    print(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
