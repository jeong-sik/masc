"""Apple container run flags for a Keeper VM whose first process is the
masc-exec-shim --serve agent (RFC microvm-guest-agent-over-socket 3.6, 6.1).

argv: <stage dir> <socket dir> <results json>

The stage dir holds out/masc-exec-shim and out/masc-exec-shim.conf, as
agent_l3.py builds them. Host sockets go under the socket dir.

Each case starts a fresh VM with --rm and stops it at the end. The first
process is set with --entrypoint, as masc renders it.

1. explicit_root: --user 0:0. What `container inspect` reports under
   .[0].configuration (the fields masc reads), and whether the agent says
   hello.
2. no_user: no --user, the run measured before, for comparison.
3. stale_socket: a socket file left at the host path before the run.
4. stale_regular_file: a regular file at the host path.
5. missing_parent: the host path's directory does not exist.
6. long_path: a host path longer than macOS's 104-byte sun_path.

Every case that starts records the host path's kind before the run, while
the VM runs, and after it is gone.
"""

import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import time
from typing import Any

STAGE, SOCKET_DIR, RESULTS = sys.argv[1:4]
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
GUEST_SOCKET = "/run/masc-agent/agent.sock"
SHIM_DIR = "/opt/masc-exec-shim"
KEEPER_IDS = "502:20"
RUN_FLAGS = [
    "--cap-drop", "ALL", "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
    "--cap-add", "CAP_SYS_ADMIN", "--tmpfs", "/tmp", "-m", "1G", "-c", "1",
]
CONFIG_KEYS = ("readOnly", "capDrop", "capAdd", "publishedSockets", "useInit")
HELLO_WAIT_SEC = 1.0
READY_WAIT_SEC = 30.0
GONE_WAIT_SEC = 30.0
SUN_PATH_BYTES = 104


def sh(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True)


def file_kind(path: str) -> str:
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return "absent"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISDIR(mode):
        return "directory"
    return "other"


def hello(path: str) -> dict[str, Any]:
    """Connect until the first byte is a hello or the wait runs out."""
    started = time.time()
    attempts, last = 0, "not tried"
    while time.time() - started < READY_WAIT_SEC:
        attempts += 1
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.settimeout(HELLO_WAIT_SEC)
            conn.connect(path)
            first = conn.recv(1)
            if first == b"\x01":
                return {"hello": True, "attempts": attempts,
                        "seconds": round(time.time() - started, 3)}
            last = "eof" if first == b"" else f"byte {first!r}"
        except socket.timeout:
            last = "silent"
        except OSError as error:
            last = f"{type(error).__name__}: {error.strerror or error}"
            if "too long" in str(error):
                break
        finally:
            conn.close()
        time.sleep(0.1)
    return {"hello": False, "attempts": attempts, "last": last,
            "seconds": round(time.time() - started, 3)}


def inspect(name: str) -> dict[str, Any]:
    out = sh(["container", "inspect", name])
    if out.returncode != 0:
        return {"inspect_rc": out.returncode, "stderr": out.stderr.strip()[-400:]}
    configuration = json.loads(out.stdout)[0].get("configuration", {})
    init = configuration.get("initProcess", {})
    facts: dict[str, Any] = {key: configuration.get(key) for key in CONFIG_KEYS}
    facts["userString"] = init.get("user", {}).get("raw", {}).get("userString")
    facts["executable"] = init.get("executable")
    facts["arguments"] = init.get("arguments")
    return facts


def gone(name: str) -> bool:
    started = time.time()
    while time.time() - started < GONE_WAIT_SEC:
        if sh(["container", "inspect", name]).returncode != 0:
            return True
        time.sleep(0.5)
    return False


def run(name: str, host_socket: str, user: list[str]) -> subprocess.CompletedProcess[str]:
    return sh(["container", "run", "-d", "--rm", "--name", name, *user, *RUN_FLAGS,
               "-v", f"{os.path.join(STAGE, 'out')}:{SHIM_DIR}:ro",
               "--env", f"MASC_EXEC_SHIM_CONFIG={SHIM_DIR}/masc-exec-shim.conf",
               "--publish-socket", f"{host_socket}:{GUEST_SOCKET}",
               "--entrypoint", f"{SHIM_DIR}/masc-exec-shim",
               IMAGE, "--serve", GUEST_SOCKET, KEEPER_IDS])


def case(label: str, host_socket: str, user: list[str],
         prepare: Any = None, keep_running: bool = False) -> dict[str, Any]:
    name = f"masc-agent-flags-{label.replace('_', '-')}-{int(time.time())}"
    if prepare is not None:
        prepare(host_socket)
    record: dict[str, Any] = {
        "case": label, "name": name, "host_socket": host_socket,
        "host_socket_bytes": len(host_socket.encode()),
        "before": file_kind(host_socket),
    }
    started = sh_time = time.time()
    result = run(name, host_socket, user)
    record["run_rc"] = result.returncode
    record["run_stderr"] = result.stderr.strip()[-400:]
    record["run_seconds"] = round(time.time() - sh_time, 3)
    if result.returncode == 0:
        record["while_running"] = file_kind(host_socket)
        record["connect"] = hello(host_socket)
        record["inspect"] = inspect(name)
        if not keep_running:
            record["stop_rc"] = sh(["container", "stop", name]).returncode
            record["gone"] = gone(name)
            record["after_stop"] = file_kind(host_socket)
    record["seconds"] = round(time.time() - started, 3)
    return record


def stale_socket(path: str) -> None:
    left = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    left.bind(path)
    left.close()


def stale_regular_file(path: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("not a socket\n")


def remove(path: str) -> None:
    if file_kind(path) in ("socket", "regular"):
        os.unlink(path)


def main() -> None:
    os.makedirs(SOCKET_DIR, exist_ok=True)
    version = sh(["container", "--version"]).stdout.strip()
    paths = {
        "explicit_root": os.path.join(SOCKET_DIR, "root.sock"),
        "no_user": os.path.join(SOCKET_DIR, "nouser.sock"),
        "stale_socket": os.path.join(SOCKET_DIR, "stale.sock"),
        "stale_regular_file": os.path.join(SOCKET_DIR, "file.sock"),
        "missing_parent": os.path.join(SOCKET_DIR, "absent-dir", "agent.sock"),
    }
    long_dir = os.path.join(SOCKET_DIR, "d" * max(1, SUN_PATH_BYTES + 8 - len(SOCKET_DIR) - 12))
    os.makedirs(long_dir, exist_ok=True)
    paths["long_path"] = os.path.join(long_dir, "agent.sock")
    for path in paths.values():
        remove(path)
    shutil.rmtree(os.path.dirname(paths["missing_parent"]), ignore_errors=True)
    cases = [
        case("explicit_root", paths["explicit_root"], ["--user", "0:0"]),
        case("no_user", paths["no_user"], []),
        case("stale_socket", paths["stale_socket"], ["--user", "0:0"], prepare=stale_socket),
        case("stale_regular_file", paths["stale_regular_file"], ["--user", "0:0"],
             prepare=stale_regular_file),
        case("missing_parent", paths["missing_parent"], ["--user", "0:0"]),
        case("long_path", paths["long_path"], ["--user", "0:0"]),
    ]
    results = {"container_version": version, "image": IMAGE, "guest_socket": GUEST_SOCKET,
               "run_flags": RUN_FLAGS, "cases": cases}
    with open(RESULTS, "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=1)
    for record in cases:
        print(record["case"], record.get("run_rc"), record.get("connect", {}).get("hello"),
              record.get("before"), record.get("while_running"), record.get("after_stop"))


if __name__ == "__main__":
    main()
