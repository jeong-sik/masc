"""The real masc-exec-shim --serve agent as an Apple container VM's first
process, reached from the host through --publish-socket.

argv: <worktree> <stage dir> <host socket path> <results json>

1. Builds the shim from the worktree's sources (scripts/build-shim-static.sh
   --print-sources) inside the sandbox image, linked dynamically against that
   image. A stage that already holds a build of the same sources is reused.
2. Starts a VM with the run flags RFC section 0 settled: a writable root,
   --cap-drop ALL plus CAP_SETUID, CAP_SETGID and CAP_SYS_ADMIN, no --user,
   the shim directory read-only, a work directory, /tmp as tmpfs.
3. Opens one connection the moment the VM is up and leaves it unread, then
   connects again until a hello arrives (a connection gets one second).
4. A probe, a payload that reports what it can reach, two requests at once,
   a burst with the runtime's pipe count before and after, and a client that
   closes in the middle of a request.
5. Last, whether the first connection ever got a byte or an end.
"""

import base64
import hashlib
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from typing import Any

WORKTREE, STAGE, HOST_SOCKET, RESULTS = sys.argv[1:5]
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
NAME = f"masc-agent-l3-{int(time.time())}"
GUEST_SOCKET = "/run/masc-agent/agent.sock"
SHIM_DIR = "/opt/masc-exec-shim"
WORK = "/masc-work"
KEEPER_UID, KEEPER_GID = 502, 20
RUN_FLAGS = [
    "--cap-drop", "ALL", "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
    "--cap-add", "CAP_SYS_ADMIN", "--tmpfs", "/tmp", "-m", "1G", "-c", "1",
]
LSOF_COLUMNS_ORPHAN = 7  # lsof prints a pipe whose peer closed without a NAME column
BURST = 50
HELLO_WAIT_SEC = 1.0
READY_WAIT_SEC = 60.0
READ_WAIT_SEC = 60.0
KIND_HELLO, KIND_STDOUT, KIND_STDERR, KIND_EXIT = 1, 2, 3, 4
RUN, PROBE = b"R", b"P"
# Connections that ended or stayed silent before a hello, after the first hello.
QUIET_AFTER_READY = [0]


def sh(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True)


def sources_digest(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(os.path.basename(path).encode() + b"\0")
        with open(path, "rb") as f:
            digest.update(f.read())
    return digest.hexdigest()


def build() -> dict[str, object]:
    src, out, work = (os.path.join(STAGE, part) for part in ("src", "out", "work"))
    listing = sh([os.path.join(WORKTREE, "scripts/build-shim-static.sh"), "--print-sources"])
    paths = listing.stdout.split()
    digest = sources_digest(paths)
    binary = os.path.join(out, "masc-exec-shim")
    stamp = os.path.join(out, "sources.sha256")
    reused = os.path.exists(binary) and os.path.exists(stamp) and open(stamp).read() == digest
    started = time.time()
    if not reused:
        shutil.rmtree(STAGE, ignore_errors=True)
        os.makedirs(src)
        os.makedirs(out)
        for path in paths:
            shutil.copy(path, src)
        with open(os.path.join(src, "shim_build_id.ml"), "w") as f:
            f.write('let suffix = "+l3check"\nlet release = ""\n')
        with open(os.path.join(src, "dune-project"), "w") as f:
            f.write("(lang dune 3.0)\n")
        with open(os.path.join(src, "dune"), "w") as f:
            f.write("(library (name exec_ssh_protocol) (modules exec_ssh_protocol)"
                    " (libraries yojson base64 uuidm))\n"
                    "(include shim_libraries.inc)\n"
                    "(executable (name masc_exec_shim) (modules masc_exec_shim) (libraries exec_shim))\n")
        result = sh(["container", "run", "--rm", "-v", f"{src}:/src:ro", "-v", f"{out}:/out", IMAGE,
                     "sh", "-euc",
                     "export PATH=/home/opam/.opam/5.5/bin:$PATH; cp -r /src /tmp/work; cd /tmp/work; "
                     "dune build ./masc_exec_shim.exe 2>&1; "
                     "cp _build/default/masc_exec_shim.exe /out/masc-exec-shim"])
        if result.returncode != 0:
            raise RuntimeError(f"build failed: {result.stdout[-3000:]}{result.stderr[-3000:]}")
        with open(stamp, "w") as f:
            f.write(digest)
    config = os.path.join(out, "masc-exec-shim.conf")
    with open(config, "w") as f:
        f.write(f"remote_root={WORK}\nscratch_root=/tmp\n")
    os.chmod(config, 0o644)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(binary, "rb") as f:
        shim_sha256 = hashlib.sha256(f.read()).hexdigest()
    return {"reused": reused, "seconds": round(time.time() - started, 1),
            "sources_sha256": digest, "shim_sha256": shim_sha256}


def start() -> dict[str, object]:
    os.makedirs(os.path.dirname(HOST_SOCKET), exist_ok=True)
    if os.path.exists(HOST_SOCKET):
        os.unlink(HOST_SOCKET)
    argv = ["container", "run", "-d", "--rm", "--name", NAME, *RUN_FLAGS,
            "-v", f"{os.path.join(STAGE, 'out')}:{SHIM_DIR}:ro",
            "-v", f"{os.path.join(STAGE, 'work')}:{WORK}", "-w", WORK,
            "--env", "HOME=/tmp", "--env", f"MASC_EXEC_SHIM_CONFIG={SHIM_DIR}/masc-exec-shim.conf",
            "--publish-socket", f"{HOST_SOCKET}:{GUEST_SOCKET}",
            IMAGE, f"{SHIM_DIR}/masc-exec-shim", "--serve", GUEST_SOCKET, f"{KEEPER_UID}:{KEEPER_GID}"]
    result = sh(argv)
    if result.returncode != 0:
        raise RuntimeError(f"container run failed: {result.stderr[-600:]}")
    return {"argv": argv}


def runtime_pid() -> int | None:
    for line in sh(["ps", "-axo", "pid=,command="]).stdout.splitlines():
        if "container-runtime-linux start" in line and f"--uuid {NAME}" in line:
            return int(line.split()[0])
    return None


def pipes(pid: int) -> dict[str, int]:
    orphan = connected = 0
    for line in sh(["lsof", "-n", "-w", "-p", str(pid)]).stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) < LSOF_COLUMNS_ORPHAN or fields[4] != "PIPE":
            continue
        if len(fields) == LSOF_COLUMNS_ORPHAN:
            orphan += 1
        else:
            connected += 1
    return {"orphan": orphan, "connected": connected}


def recv_exact(conn: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        piece = conn.recv(size - len(data))
        if not piece:
            raise EOFError(f"stream ended after {len(data)} of {size} bytes")
        data += piece
    return data


def read_chunk(conn: socket.socket) -> tuple[int, bytes] | None:
    header = conn.recv(1)
    if not header:
        return None
    (length,) = struct.unpack(">I", recv_exact(conn, 4))
    return header[0], recv_exact(conn, length)


def connect_until_hello() -> tuple[socket.socket, dict[str, object], int]:
    """A connection whose hello arrived, and how many went quiet first."""
    end = time.time() + READY_WAIT_SEC
    quiet = 0
    while True:
        conn = socket.socket(socket.AF_UNIX)
        try:
            conn.settimeout(HELLO_WAIT_SEC)
            conn.connect(HOST_SOCKET)
            chunk = read_chunk(conn)
            if chunk is None:
                raise EOFError("closed before the hello")
            kind, payload = chunk
            if kind != KIND_HELLO:
                raise RuntimeError(f"first chunk kind {kind}")
            conn.settimeout(READ_WAIT_SEC)
            return conn, json.loads(payload), quiet
        except (OSError, EOFError):
            conn.close()
            quiet += 1
            if time.time() > end:
                raise


def read_rest(conn: socket.socket) -> tuple[bytes, bytes, list[dict[str, int]]]:
    out, err, exits = b"", b"", []
    while True:
        chunk = read_chunk(conn)
        if chunk is None:
            return out, err, exits
        kind, payload = chunk
        if kind == KIND_STDOUT:
            out += payload
        elif kind == KIND_STDERR:
            err += payload
        elif kind == KIND_EXIT:
            value = struct.unpack(">i", payload[1:5])[0]
            exits.append({"exited" if payload[0] == 0 else "signaled": value})
        else:
            raise RuntimeError(f"unexpected chunk kind {kind}")


def frame(argv: list[str], timeout_sec: float = 30.0) -> bytes:
    def encode(text: str) -> str:
        return base64.b64encode(text.encode()).decode()

    body = json.dumps({"v": 3, "argv": [encode(a) for a in argv], "env": [], "cwd": encode(WORK),
                       "remote_root": encode(WORK), "timeout_sec": timeout_sec, "stdin_len": 0,
                       "mode": "effect", "acceptance_frame": True}).encode()
    return struct.pack(">Q", len(body)) + body


def trailer(err: bytes) -> dict[str, Any]:
    last = err.rfind(b"\x1e")
    first = err.rfind(b"\x1e", 0, last)
    return json.loads(err[first + 1:last])["masc_exec_result"]


def request(argv: list[str]) -> dict[str, Any]:
    started = time.time()
    conn, hello, quiet = connect_until_hello()
    QUIET_AFTER_READY[0] += quiet
    conn.sendall(RUN + frame(argv))
    out, err, exits = read_rest(conn)
    conn.close()
    return {"hello": hello, "stdout": out.decode(errors="replace"), "exits": exits,
            "trailer": trailer(err), "ms": round((time.time() - started) * 1000, 1)}


PAYLOAD = r"""
echo "id_u=$(id -u) id_g=$(id -g) id_groups=$(id -G)"
touch /var/tmp/l3-probe 2>/dev/null; echo "rootfs_write_rc=$?"
touch /tmp/l3-probe 2>/dev/null; echo "tmpfs_write_rc=$?"
touch /masc-work/l3-probe 2>/dev/null; echo "work_write_rc=$?"
ls /run/masc-agent >/dev/null 2>&1; echo "socket_dir_rc=$?"
ls /proc/1/fd >/dev/null 2>&1; echo "agent_fd_listing_rc=$?"
grep -E '^(NoNewPrivs|CapEff|CapPrm|CapBnd):' /proc/self/status | tr '\t' ' '
grep -E '^(Uid|Gid|NoNewPrivs|CapEff):' /proc/1/status | sed 's/^/agent_/' | tr '\t' ' '
python3 -c '
import socket
s = socket.socket(socket.AF_UNIX)
try:
    s.connect("/run/masc-agent/agent.sock"); print("hijack_connect=ok")
except OSError as e:
    print("hijack_connect=" + e.strerror)
'
echo payload-stderr >&2
exit 7
"""


def measure(results: dict[str, Any]) -> None:
    run_returned = time.time()
    early = socket.socket(socket.AF_UNIX)
    early_connected = False
    for _ in range(200):
        try:
            early.connect(HOST_SOCKET)
            early_connected = True
            break
        except OSError:
            time.sleep(0.05)
    early_at = time.time()
    conn, hello, quiet = connect_until_hello()
    conn.close()
    results["ready"] = {"early_connected": early_connected,
                        "early_connect_after_run_ms": round((early_at - run_returned) * 1000),
                        "quiet_connections_before_hello": quiet,
                        "hello_after_run_ms": round((time.time() - run_returned) * 1000),
                        "hello": hello}
    conn, _, _ = connect_until_hello()
    conn.sendall(PROBE)
    out, _, exits = read_rest(conn)
    conn.close()
    probe = json.loads(out)
    results["probe"] = {"name": probe["name"], "version": probe["version"],
                        "capabilities": probe["capabilities"], "exits": exits}
    report = request(["sh", "-c", PAYLOAD])
    results["payload"] = {"lines": str(report["stdout"]).splitlines(), "exits": report["exits"],
                          "trailer_exit": report["trailer"].get("exit"), "ms": report["ms"]}
    slow: dict[str, Any] = {}
    thread = threading.Thread(target=lambda: slow.update(request(["sh", "-c", "sleep 2; echo slow"])))
    thread.start()
    time.sleep(0.3)
    quick = request(["sh", "-c", "echo quick"])
    thread.join()
    results["concurrent"] = {"quick_ms": quick["ms"], "slow_ms": slow.get("ms"),
                             "quick_stdout": quick["stdout"], "slow_stdout": slow.get("stdout")}
    pid = runtime_pid()
    before = pipes(pid) if pid else None
    latencies: list[float] = []
    wrong = 0
    for index in range(BURST):
        report = request(["sh", "-c", f"echo {index}"])
        latencies.append(float(report["ms"]))
        wrong += report["stdout"] != f"{index}\n" or report["trailer"].get("exit") != 0
    after = pipes(pid) if pid else None
    latencies.sort()
    results["burst"] = {"n": BURST, "wrong": wrong, "p50_ms": latencies[BURST // 2],
                        "max_ms": latencies[-1], "runtime_pid": pid,
                        "pipes_before": before, "pipes_after": after}
    conn, _, _ = connect_until_hello()
    conn.sendall(RUN + frame(["sh", "-c", "sleep 30; echo late > /masc-work/late"]))
    time.sleep(0.5)
    conn.close()
    time.sleep(4)
    left = request(["sh", "-c", "ps -eo args | grep -c '^sleep 30' || true"])
    results["cancel"] = {"late_file_exists": os.path.exists(os.path.join(STAGE, "work", "late")),
                         "sleep_processes_left": str(left["stdout"]).strip()}
    early.settimeout(1.0)
    try:
        piece = early.recv(1)
        early_end = "eof" if piece == b"" else f"byte {piece!r}"
    except socket.timeout:
        early_end = "nothing"
    results["ready"]["early_after_s"] = round(time.time() - early_at)
    results["ready"]["early_outcome"] = early_end
    results["quiet_connections_after_ready"] = QUIET_AFTER_READY[0]
    early.close()


def main() -> None:
    results: dict[str, Any] = {
        "image": IMAGE, "name": NAME, "keeper": f"{KEEPER_UID}:{KEEPER_GID}",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "worktree_head": sh(["git", "-C", WORKTREE, "rev-parse", "HEAD"]).stdout.strip(),
        "worktree_dirty": sh(["git", "-C", WORKTREE, "status", "--porcelain", "lib", "bin",
                              "scripts"]).stdout.strip() != "",
        "container_version": sh(["container", "--version"]).stdout.strip(),
    }
    results["build"] = build()
    results["start"] = start()
    try:
        measure(results)
    except Exception as error:  # record it and still stop the VM
        results["error"] = repr(error)
    finally:
        results["agent_logs"] = sh(["container", "logs", NAME]).stdout[-2000:]
        results["stop_rc"] = sh(["container", "stop", NAME]).returncode
    with open(RESULTS, "w") as f:
        json.dump(results, f, indent=1)
    print(json.dumps({key: results.get(key) for key in
                      ("build", "ready", "quiet_connections_after_ready", "probe", "payload",
                       "concurrent", "burst", "cancel", "error")},
                     indent=1))


if __name__ == "__main__":
    main()
