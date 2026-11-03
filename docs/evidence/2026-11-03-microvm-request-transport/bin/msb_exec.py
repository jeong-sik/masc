"""Does `msb exec --stream` leave pipe ends behind on the host?

One scratch microsandbox (alpine, cached). Orphan pipe fds are counted across
every host process whose command line names msb/krun, before and after:
  stream_devnull : 30 x `msb exec --stream NAME -- true` with stdin=/dev/null
  stream_pipe    : 30 x the same with 2 KiB piped in to `cat`
  plain          : 30 x `msb exec NAME -- true`
"""

import json
import os
import statistics
import subprocess
import time

NAME = "masc-msbprobe-20261103"
LSOF_COLUMNS_ORPHAN = 7


def msb_pids():
    listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True).stdout
    return [int(line.split()[0]) for line in listing.splitlines()
            if ("msb" in line or "krun" in line) and "msb_exec.py" not in line and "ps -axo" not in line]


def orphans():
    pids = msb_pids()
    if not pids:
        return 0, []
    listing = subprocess.run(["lsof", "-n", "-w", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    count = sum(1 for line in listing.splitlines()[1:]
                if len(line.split()) == LSOF_COLUMNS_ORPHAN and line.split()[4] == "PIPE")
    return count, pids


def phase(label, argv, stdin_bytes=None):
    before, pids_before = orphans()
    lat, fails, note = [], 0, ""
    for _ in range(30):
        start = time.monotonic()
        proc = subprocess.run(argv, input=stdin_bytes, stdin=None if stdin_bytes else subprocess.DEVNULL,
                              capture_output=True)
        lat.append(time.monotonic() - start)
        if proc.returncode != 0:
            fails += 1
            note = proc.stderr.decode(errors="replace").strip()[-200:]
    after, pids_after = orphans()
    print(json.dumps({"phase": label, "orphans_before": before, "orphans_after": after, "failures": fails,
                      "note": note, "p50_ms": round(statistics.median(lat) * 1000),
                      "max_ms": round(max(lat) * 1000), "host_pids": len(pids_after)}), flush=True)


def main():
    subprocess.run(["msb", "rm", "--force", NAME], capture_output=True)
    created = subprocess.run(["msb", "create", "--name", NAME, "alpine"], capture_output=True, text=True)
    if created.returncode != 0:
        print(json.dumps({"create_rc": created.returncode, "err": created.stderr.strip()[-300:]}))
        return
    try:
        time.sleep(2)
        print(json.dumps({"ready_orphans": orphans()[0], "pids": orphans()[1]}), flush=True)
        phase("stream_devnull", ["msb", "exec", "--stream", NAME, "--", "true"])
        phase("stream_pipe", ["msb", "exec", "--stream", NAME, "--", "cat"], stdin_bytes=os.urandom(2048))
        phase("plain", ["msb", "exec", NAME, "--", "true"])
    finally:
        subprocess.run(["msb", "stop", NAME], capture_output=True)
        subprocess.run(["msb", "rm", "--force", NAME], capture_output=True)


if __name__ == "__main__":
    main()
