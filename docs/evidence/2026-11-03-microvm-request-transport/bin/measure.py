"""Compare request transports into one scratch Apple container guest.

Phases run against a single scratch container (not a Keeper VM):
  ssh_true, ssh_stdin, ssh_big_stdout, exec_plain, exec_i (positive control),
  ssh_parallel, cancel_sigkill, cancel_sigterm.
For each phase: orphan/connected pipe fds of the guest's container-runtime-linux
process before and after, wall latency per call, failures.
"""

import json
import os
import signal
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CONTAINER = "/opt/homebrew/bin/container"
NAME = "masc-sshprobe-20261103"
IMAGE = "masc-ssh-wkbl-team:20261028"
PORT = 22299
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "kit")
KEY = os.path.join(ROOT, "client", "id_probe")
KNOWN = os.path.join(ROOT, "client", "known_hosts")
OUT = os.path.join(ROOT, "results.json")
LSOF_COLUMNS_ORPHAN = 7  # lsof prints a pipe whose peer closed without a NAME column
PIPE = "PIPE"

SSH = [
    "ssh", "-T", "-p", str(PORT), "-i", KEY,
    "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
    "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={KNOWN}",
    "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=15",
    "-o", "LogLevel=ERROR", "probe@127.0.0.1",
]


def runtime_pid() -> int:
    listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True).stdout
    for line in listing.splitlines():
        if "container-runtime-linux start" in line and f"--uuid {NAME}" in line:
            return int(line.split()[0])
    raise RuntimeError("runtime pid not found")


def pipes(pid: int) -> tuple[int, int]:
    listing = subprocess.run(["lsof", "-n", "-w", "-p", str(pid)], capture_output=True, text=True).stdout
    orphan = connected = 0
    for line in listing.splitlines()[1:]:
        fields = line.split()
        if len(fields) < LSOF_COLUMNS_ORPHAN or fields[4] != PIPE:
            continue
        if len(fields) == LSOF_COLUMNS_ORPHAN:
            orphan += 1
        else:
            connected += 1
    return orphan, connected


def timed(argv, stdin_bytes=None, stdin_devnull=False):
    start = time.monotonic()
    proc = subprocess.run(
        argv,
        input=stdin_bytes,
        stdin=subprocess.DEVNULL if stdin_devnull else None,
        capture_output=True,
    )
    return time.monotonic() - start, proc.returncode, len(proc.stdout), proc.stderr[-200:].decode(errors="replace")


def summarize(lat):
    if not lat:
        return {}
    ordered = sorted(lat)
    p90 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.9))]
    return {"n": len(lat), "p50_ms": round(statistics.median(lat) * 1000), "p90_ms": round(p90 * 1000), "max_ms": round(max(lat) * 1000)}


def phase(pid, label, calls):
    before = pipes(pid)
    lat, fails, notes = [], 0, []
    for call in calls:
        seconds, code, out_len, err = call()
        lat.append(seconds)
        if code != 0:
            fails += 1
            if len(notes) < 3:
                notes.append(f"rc={code} {err.strip()}")
    after = pipes(pid)
    result = {"phase": label, "pipes_before": before, "pipes_after": after,
              "orphan_delta": after[0] - before[0], "failures": fails, "notes": notes, **summarize(lat)}
    print(json.dumps(result), flush=True)
    return result


def cancel_phase(pid, label, sig, n):
    before = pipes(pid)
    subprocess.run(SSH + ["rm -f /tmp/eof.*"], capture_output=True)
    for i in range(n):
        proc = subprocess.Popen(SSH + [f"cat >/dev/null; touch /tmp/eof.{label}.{i}"],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)
        proc.send_signal(sig)
        proc.wait(timeout=10)
    time.sleep(3.0)
    seen = subprocess.run(SSH + [f"ls /tmp | grep -c '^eof\\.{label}\\.' || true"], capture_output=True, text=True).stdout.strip()
    leftover = subprocess.run(SSH + ["pgrep -c -x cat || true"], capture_output=True, text=True).stdout.strip()
    after = pipes(pid)
    result = {"phase": label, "calls": n, "guest_saw_eof": seen, "guest_cat_still_running": leftover,
              "pipes_before": before, "pipes_after": after, "orphan_delta": after[0] - before[0]}
    print(json.dumps(result), flush=True)
    return result


def parallel_phase(pid, n):
    before = pipes(pid)
    with ThreadPoolExecutor(max_workers=n) as pool:
        outcomes = list(pool.map(lambda _: timed(SSH + ["true"]), range(n)))
    after = pipes(pid)
    lat = [o[0] for o in outcomes]
    fails = [o for o in outcomes if o[1] != 0]
    result = {"phase": f"ssh_parallel_{n}", "failures": len(fails), "notes": [f"rc={f[1]} {f[3].strip()}" for f in fails[:3]],
              "pipes_before": before, "pipes_after": after, "orphan_delta": after[0] - before[0], **summarize(lat)}
    print(json.dumps(result), flush=True)
    return result


def start():
    subprocess.run([CONTAINER, "run", "-d", "--name", NAME, "-m", "1G", "-c", "2",
                    "-p", f"127.0.0.1:{PORT}:22", "-v", f"{KIT}:/opt/probe:ro",
                    "--entrypoint", "/bin/sh", IMAGE, "/opt/probe/entrypoint.sh"], check=True, capture_output=True)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if subprocess.run(SSH + ["true"], capture_output=True).returncode == 0:
            return
        time.sleep(2)
    raise RuntimeError("sshd did not answer within 120s")


def stop():
    subprocess.run([CONTAINER, "stop", NAME], capture_output=True)
    subprocess.run([CONTAINER, "delete", "--force", NAME], capture_output=True)


def main():
    stop()
    if os.path.exists(KNOWN):
        os.remove(KNOWN)
    results = {"started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    try:
        start()
        pid = runtime_pid()
        results["runtime_pid"] = pid
        results["pipes_at_ready"] = pipes(pid)
        frame = os.urandom(2048)
        exec_prefix = [CONTAINER, "exec", "--user", "5100:5100", NAME]
        phases = [
            phase(pid, "ssh_true", [lambda: timed(SSH + ["true"])] * 100),
            phase(pid, "ssh_stdin_2k", [lambda: timed(SSH + ["cat >/dev/null"], stdin_bytes=frame)] * 100),
            phase(pid, "ssh_stdout_70k", [lambda: timed(SSH + ["head -c 70000 /dev/zero"])] * 30),
            phase(pid, "exec_plain", [lambda: timed(exec_prefix + ["true"], stdin_devnull=True)] * 50),
            phase(pid, "exec_i_control", [lambda: timed([CONTAINER, "exec", "-i", "--user", "5100:5100", NAME, "true"], stdin_devnull=True)] * 20),
            parallel_phase(pid, 20),
            cancel_phase(pid, "cancel_sigkill", signal.SIGKILL, 10),
            cancel_phase(pid, "cancel_sigterm", signal.SIGTERM, 10),
        ]
        results["phases"] = phases
        results["pipes_at_end"] = pipes(pid)
    finally:
        stop()
        with open(OUT, "w") as handle:
            json.dump(results, handle, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
