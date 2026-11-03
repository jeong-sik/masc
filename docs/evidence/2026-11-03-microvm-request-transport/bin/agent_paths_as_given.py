"""Whether Apple container reports host paths as given or resolved, for an
agent VM whose host socket and identity mount go through a symlinked
directory. agent_plan_boot.py is the check that uses masc's own renderer and
parser; this script assembles the argv in Python, in the order
render_turn_start_argv_for (keeper_sandbox_microvm.ml) writes it: run -d
--name, labels, --user, constraint flags, grant flags, --memory, --cpus, env,
mounts, --workdir, network, --entrypoint, image, arguments.

argv: <stage dir> <socket dir> <results json>

The plan mirrors requested_apple_plan (keeper_turn_sandbox_runtime.ml) with
the agent deltas: --user 0:0, no Read_only_rootfs, three capabilities, one
published socket, the shim as first process.

Case "renderer": real directories. Case "symlinked": the host socket and the
identity mount go through a symlink to the same directory. Facts are read
from `container inspect` in Python, the way apple_guest_facts reads them.
The request cwd comes from VERIFY_CWD (default /masc-work).

No sandbox-kind label is set, so masc's guest sweeps do not select these VMs.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time
from typing import Any

STAGE, SOCKET_DIR, RESULTS = sys.argv[1:4]
IMAGE = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
SHIM_DIR = "/opt/masc-exec-shim"
SHIM = f"{SHIM_DIR}/masc-exec-shim"
SHIM_CONFIG = f"{SHIM_DIR}/masc-exec-shim.conf"
GUEST_SOCKET = "/run/masc-agent/agent.sock"
WORK, BUILD = "/masc-work", "/masc-build"
IDENTITY_DEST = "/masc-identity"
KEEPER_UID, KEEPER_GID = 502, 20
MEMORY_MIB, CPUS = 1024, 1
CAPS = ["CAP_SETUID", "CAP_SETGID", "CAP_SYS_ADMIN"]
PLAN_LABEL_KEY = "masc.mcp.boot_plan"
PLACEHOLDER_DIGEST = "0" * 64
HELLO_WAIT_SEC = 1.0
READY_WAIT_SEC = 60.0
KIND_HELLO, KIND_STDOUT, KIND_STDERR, KIND_EXIT = 1, 2, 3, 4
RUN, PROBE = b"R", b"P"
CWD = os.environ.get("VERIFY_CWD", WORK)


def sh(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True)


def plan_for(stamp: str, host_socket: str, identity_dir: str) -> dict[str, Any]:
    return {
        "image": IMAGE,
        "user": "0:0",
        "working_directory": WORK,
        "command": [SHIM, "--serve", GUEST_SOCKET, f"{KEEPER_UID}:{KEEPER_GID}"],
        # requested_apple_plan's order: identity, work, build, shim.
        "mounts": [
            ("host_dir", identity_dir, IDENTITY_DEST, True),
            ("volume", f"masc-verify-work-{stamp}", WORK, False),
            ("volume", f"masc-verify-build-{stamp}", BUILD, False),
            ("host_dir", os.path.join(STAGE, "out"), SHIM_DIR, True),
        ],
        # all_guest_constraints without Read_only_rootfs, in its order.
        "isolation": ["drop_all_capabilities", "remove_on_exit", "scratch_tmpfs"],
        "caps": CAPS,
        "sockets": [(host_socket, GUEST_SOCKET)],
        "network": "none",
        "environment": [("HOME", "/tmp"), ("MASC_EXEC_SHIM_CONFIG", SHIM_CONFIG),
                        ("GH_CONFIG_DIR", IDENTITY_DEST)],
        "labels": [("verify.keeper", "l5a-agent"), ("masc.mcp.microvm_backend", "apple_container")],
    }


CONSTRAINT_FLAGS = {
    "drop_all_capabilities": ["--cap-drop", "ALL"],
    "read_only_rootfs": ["--read-only"],
    "remove_on_exit": ["--rm"],
    "scratch_tmpfs": ["--tmpfs", "/tmp"],
}


def render(name: str, plan: dict[str, Any]) -> list[str]:
    labels = plan["labels"] + [("verify.owner_pid", str(os.getpid())),
                               ("verify.started_at", str(int(time.time()))),
                               (PLAN_LABEL_KEY, PLACEHOLDER_DIGEST)]
    argv = ["container", "run", "-d", "--name", name]
    for key, value in labels:
        argv += ["--label", f"{key}={value}"]
    argv += ["--user", plan["user"]]
    for constraint in plan["isolation"]:
        argv += CONSTRAINT_FLAGS[constraint]
    for cap in plan["caps"]:
        argv += ["--cap-add", cap]
    for host, guest in plan["sockets"]:
        argv += ["--publish-socket", f"{host}:{guest}"]
    argv += ["--memory", f"{MEMORY_MIB}m", "--cpus", str(CPUS)]
    for key, value in plan["environment"]:
        argv += ["--env", f"{key}={value}"]
    for kind, source, destination, read_only in plan["mounts"]:
        if kind == "host_dir":
            argv += ["-v", f"{source}:{destination}" + (":ro" if read_only else "")]
        else:
            argv += ["--volume", f"{source}:{destination}"]
    argv += ["--workdir", plan["working_directory"]]
    argv += ["--network", "none"] if plan["network"] == "none" else []
    argv += ["--entrypoint", plan["command"][0], plan["image"], *plan["command"][1:]]
    return argv


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


def connect_until_hello(path: str) -> tuple[socket.socket, dict[str, Any], int]:
    end = time.time() + READY_WAIT_SEC
    attempts = 0
    while True:
        attempts += 1
        conn = socket.socket(socket.AF_UNIX)
        try:
            conn.settimeout(HELLO_WAIT_SEC)
            conn.connect(path)
            chunk = read_chunk(conn)
            if chunk is None:
                raise EOFError("closed before the hello")
            kind, payload = chunk
            if kind != KIND_HELLO:
                raise RuntimeError(f"first chunk kind {kind}")
            conn.settimeout(30.0)
            return conn, json.loads(payload), attempts
        except (OSError, EOFError):
            conn.close()
            if time.time() > end:
                raise
            time.sleep(0.05)


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


def frame(argv: list[str]) -> bytes:
    def encode(text: str) -> str:
        return base64.b64encode(text.encode()).decode()

    body = json.dumps({"v": 3, "argv": [encode(a) for a in argv], "env": [], "cwd": encode(CWD),
                       "remote_root": encode(WORK), "timeout_sec": 30.0, "stdin_len": 0,
                       "mode": "effect", "acceptance_frame": True}).encode()
    return struct.pack(">Q", len(body)) + body


def trailer(err: bytes) -> dict[str, Any] | None:
    last = err.rfind(b"\x1e")
    first = err.rfind(b"\x1e", 0, last)
    if first < 0:
        return None
    return json.loads(err[first + 1:last]).get("masc_exec_result")


# --- facts as apple_guest_facts reads them --------------------------------

def facts_of(raw: str, name: str) -> dict[str, Any]:
    rows = json.loads(raw)
    assert isinstance(rows, list) and len(rows) == 1, "row count"
    row = rows[0]
    config = row["configuration"]
    assert row["id"] == name and config["id"] == name, "guest identity"
    init = config["initProcess"]
    mounts = []
    for mount in config["mounts"]:
        (kind, detail), = mount["type"].items()
        options = mount["options"]
        if kind == "tmpfs":
            assert detail == {} and options == [], f"tmpfs shape {mount}"
            mounts.append(("tmpfs", None, mount["destination"], False))
        elif kind == "virtiofs":
            assert detail == {} and options in ([], ["ro"]), f"virtiofs shape {mount}"
            mounts.append(("host_dir", mount["source"], mount["destination"], options == ["ro"]))
        elif kind == "volume":
            assert options == [], f"volume options {mount}"
            mounts.append(("volume", detail["name"], mount["destination"], False))
        else:
            raise AssertionError(f"mount type {kind}")
    environment = []
    for entry in init["environment"]:
        key, _, value = entry.partition("=")
        environment.append((key, value))
    variant = config["platform"].get("variant")
    return {
        "image": config["image"]["reference"],
        "descriptor_digest": config["image"]["descriptor"]["digest"],
        "platform": (config["platform"]["architecture"], config["platform"]["os"], variant),
        "cpus": config["resources"]["cpus"],
        "memory_bytes": config["resources"]["memoryInBytes"],
        "user": init["user"]["raw"]["userString"],
        "working_directory": init["workingDirectory"],
        "command": [init["executable"], *init["arguments"]],
        "mounts": mounts,
        "read_only": config["readOnly"],
        "cap_drop": config["capDrop"],
        "cap_add": config["capAdd"],
        "published_sockets": [(s["hostPath"], s["containerPath"]) for s in config["publishedSockets"]],
        "use_init": config["useInit"],
        "networks": [n["network"] for n in config["networks"]],
        "environment": environment,
        "labels": dict(config["labels"]),
    }


def differences(plan: dict[str, Any], facts: dict[str, Any]) -> list[str]:
    expected_mounts = list(plan["mounts"])
    if "scratch_tmpfs" in plan["isolation"]:
        expected_mounts.append(("tmpfs", None, "/tmp", False))
    found = []
    if plan["image"] != facts["image"]:
        found.append("image")
    if facts["cpus"] != CPUS or facts["memory_bytes"] != MEMORY_MIB * 1048576:
        found.append("resources")
    if plan["user"] != facts["user"]:
        found.append("user")
    if plan["working_directory"] != facts["working_directory"]:
        found.append("working_directory")
    if plan["command"] != facts["command"]:
        found.append("command")
    if sorted(expected_mounts, key=repr) != sorted(facts["mounts"], key=repr):
        found.append("mounts")
    if ("read_only_rootfs" in plan["isolation"]) != facts["read_only"]:
        found.append("root_filesystem")
    cap_drop = ["ALL"] if "drop_all_capabilities" in plan["isolation"] else []
    if sorted(cap_drop) != sorted(facts["cap_drop"]) or sorted(plan["caps"]) != sorted(facts["cap_add"]):
        found.append("capabilities")
    if sorted(plan["sockets"]) != sorted(facts["published_sockets"]):
        found.append("published_sockets")
    if facts["use_init"]:
        found.append("init_process")
    if sorted([] if plan["network"] == "none" else [plan["network"]]) != sorted(facts["networks"]):
        found.append("network")
    if not all(dict(facts["environment"]).get(k) == v for k, v in plan["environment"]):
        found.append("environment")
    if not all(facts["labels"].get(k) == v for k, v in plan["labels"]):
        found.append("labels")
    return found


PAYLOAD = r"""
echo "id=$(id -u):$(id -g) home=$HOME"
grep -E '^(NoNewPrivs|CapEff):' /proc/self/status | tr '\t' ' '
touch /var/tmp/v 2>/dev/null; echo "rootfs_write_rc=$?"
exit 3
"""


def run_case(case: str, plan: dict[str, Any], host_socket: str) -> dict[str, Any]:
    stamp = plan["mounts"][1][1].rsplit("-", 1)[1]
    name = f"masc-verify-{case}-{stamp}"
    result: dict[str, Any] = {"case": case, "name": name, "host_socket": host_socket}
    argv = render(name, plan)
    result["argv"] = argv
    started = time.time()
    ran = sh(argv)
    result["run_rc"] = ran.returncode
    if ran.returncode != 0:
        result["run_stderr"] = ran.stderr[-800:]
        return result
    result["run_seconds"] = round(time.time() - started, 3)
    try:
        conn, hello, attempts = connect_until_hello(host_socket)
        conn.close()
        result["hello"] = hello
        result["hello_attempts"] = attempts
        conn, _, _ = connect_until_hello(host_socket)
        conn.sendall(PROBE)
        out, _, exits = read_rest(conn)
        conn.close()
        probe = json.loads(out)
        result["probe"] = {"version": probe.get("version"), "capabilities": probe.get("capabilities"),
                           "exits": exits}
        conn, _, _ = connect_until_hello(host_socket)
        conn.sendall(RUN + frame(["sh", "-c", PAYLOAD]))
        out, err, exits = read_rest(conn)
        conn.close()
        result["request"] = {"cwd": CWD, "stdout": out.decode(errors="replace").splitlines(), "exits": exits,
                             "stderr": err.decode(errors="replace")[-800:],
                             "trailer": trailer(err)}
        raw = sh(["container", "inspect", name]).stdout
        result["inspect_raw"] = json.loads(raw)
        facts = facts_of(raw, name)
        result["facts"] = {k: v for k, v in facts.items() if k not in ("environment", "labels")}
        result["facts_plan_label"] = facts["labels"].get(PLAN_LABEL_KEY)
        result["differences"] = differences(plan, facts)
    finally:
        result["stop_rc"] = sh(["container", "stop", name]).returncode
        for _ in range(60):
            if sh(["container", "inspect", name]).stdout.strip() in ("", "[]"):
                break
            time.sleep(0.5)
        result["socket_after_stop"] = os.path.lexists(host_socket)
        result["resolved_socket_after_stop"] = os.path.lexists(os.path.realpath(host_socket))
    return result


def main() -> None:
    stamp = str(int(time.time()))
    os.makedirs(SOCKET_DIR, exist_ok=True)
    real = os.path.join(SOCKET_DIR, "real")
    link = os.path.join(SOCKET_DIR, "link")
    os.makedirs(os.path.join(real, "identity"), exist_ok=True)
    with open(os.path.join(real, "identity", "hosts.yml"), "w") as f:
        f.write("github.com: {}\n")
    if not os.path.islink(link):
        os.symlink(real, link)
    for volume in (f"masc-verify-work-{stamp}", f"masc-verify-build-{stamp}"):
        made = sh(["container", "volume", "create", volume])
        if made.returncode != 0:
            raise RuntimeError(f"volume create {volume}: {made.stderr}")
    results: dict[str, Any] = {"container_version": sh(["container", "--version"]).stdout.strip(),
                               "image": IMAGE, "cases": []}
    try:
        cases = [
            ("renderer", os.path.join(real, "agent.sock"), os.path.join(real, "identity")),
            ("symlinked", os.path.join(link, "agent2.sock"), os.path.join(link, "identity")),
        ]
        for case, host_socket, identity in cases:
            plan = plan_for(stamp, host_socket, identity)
            results["cases"].append(run_case(case, plan, host_socket))
    finally:
        for volume in (f"masc-verify-work-{stamp}", f"masc-verify-build-{stamp}"):
            results.setdefault("volume_delete_rc", []).append(
                sh(["container", "volume", "delete", volume]).returncode)
        with open(RESULTS, "w") as f:
            json.dump(results, f, indent=1)
    for case in results["cases"]:
        print(case["case"], "run_rc", case["run_rc"], "differences", case.get("differences"),
              "hello", case.get("hello"), "attempts", case.get("hello_attempts"))


if __name__ == "__main__":
    main()
