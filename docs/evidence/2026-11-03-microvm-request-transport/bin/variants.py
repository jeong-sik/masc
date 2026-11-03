"""Can SSH reach a guest under the run shapes Keeper VMs use?

Each case starts one scratch container, waits for an SSH answer, and removes it:
  root_net_none   : root sshd, --network none, -p 127.0.0.1:P:22
  nonroot_inherit : sshd as a non-root image user, default network, -p P:2222
  nonroot_none    : the same with --network none
"""

import json
import os
import subprocess
import time

CONTAINER = "/opt/homebrew/bin/container"
IMAGE = "masc-ssh-wkbl-team:20261028"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "kit")
KEY = os.path.join(ROOT, "client", "id_probe")
KNOWN = os.path.join(ROOT, "client", "known_hosts_variants")
WAIT_S = 90


def ssh(port, user, command):
    argv = ["ssh", "-T", "-p", str(port), "-i", KEY, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no", "-o", f"UserKnownHostsFile={KNOWN}",
            "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR", f"{user}@127.0.0.1", command]
    return subprocess.run(argv, capture_output=True, text=True)


def case(name, run_args, port, user):
    subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
    started = subprocess.run([CONTAINER, "run", "-d", "--name", name, "-m", "1G", "-c", "1",
                              "-v", f"{KIT}:/opt/probe:ro", *run_args], capture_output=True, text=True)
    result = {"case": name, "run_rc": started.returncode, "run_err": started.stderr.strip()[-300:]}
    if started.returncode == 0:
        deadline = time.monotonic() + WAIT_S
        last = None
        while time.monotonic() < deadline:
            last = ssh(port, user, "id -u; cat /proc/1/cmdline | tr '\\0' ' '")
            if last.returncode == 0:
                break
            time.sleep(3)
        result["ssh_rc"] = last.returncode if last else None
        result["ssh_out"] = (last.stdout if last else "").strip()
        result["ssh_err"] = (last.stderr if last else "").strip()[-300:]
        logs = subprocess.run([CONTAINER, "logs", name], capture_output=True, text=True)
        result["guest_log_tail"] = logs.stdout.strip()[-300:]
    subprocess.run([CONTAINER, "stop", name], capture_output=True)
    subprocess.run([CONTAINER, "delete", "--force", name], capture_output=True)
    print(json.dumps(result), flush=True)


def main():
    if os.path.exists(KNOWN):
        os.remove(KNOWN)
    case("masc-sshprobe-root-none", ["--network", "none", "-p", "127.0.0.1:22297:22",
                                     "--entrypoint", "/bin/sh", IMAGE, "/opt/probe/entrypoint.sh"], 22297, "probe")
    case("masc-sshprobe-nonroot-inherit", ["--user", "opam", "-p", "127.0.0.1:22296:2222",
                                           "--entrypoint", "/bin/sh", IMAGE, "/opt/probe/nonroot.sh"], 22296, "opam")
    case("masc-sshprobe-nonroot-none", ["--user", "opam", "--network", "none", "-p", "127.0.0.1:22295:2222",
                                        "--entrypoint", "/bin/sh", IMAGE, "/opt/probe/nonroot.sh"], 22295, "opam")


if __name__ == "__main__":
    main()
