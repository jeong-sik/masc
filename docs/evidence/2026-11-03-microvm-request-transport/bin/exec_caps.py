"""What a `container exec` process can do in an agent-shaped guest beside an
exec-shaped one, on Apple container 1.6.1.

argv: <results json>

An agent guest boots with --user 0:0, --cap-drop ALL plus CAP_SETUID,
CAP_SETGID and CAP_SYS_ADMIN, and no --read-only. Requests the agent serves
run with no_new_privs and no capabilities (agent-l3-results.json). masc's own
`container exec` calls do not go through the agent, so this records, for the
Keeper uid and for root:

1. HOME: the guest is booted with --env HOME=/tmp over an image ENV HOME.
   Does inspect list HOME once, and which value does a process see?
2. The capability sets and no_new_privs of an exec'd process.
3. The setuid-root files in the image, and whether the Keeper uid gets root
   through sudo or su without a password. Only the first character of root's
   password field is printed: `*` or `!` is a locked account.

The first process is `sleep infinity`: none of these depends on it. No exec
here uses -i, so none leaks a runtime pipe.
"""

import json
import subprocess
import sys
import time
from typing import Any

RESULTS = sys.argv[1]
IMAGES = ["masc-sandbox:general", "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"]
KEEPER = "502:20"
AGENT_FLAGS = ["--user", "0:0", "--cap-drop", "ALL", "--cap-add", "CAP_SETUID", "--cap-add",
               "CAP_SETGID", "--cap-add", "CAP_SYS_ADMIN", "--tmpfs", "/tmp"]
EXEC_FLAGS = ["--user", KEEPER, "--read-only", "--cap-drop", "ALL", "--tmpfs", "/tmp"]
PROBE = ("echo HOME=$HOME; echo id=$(id -u):$(id -g); "
         "grep -E '^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs):' /proc/self/status | tr '\\t' ' '")
ESCALATE = ("getent passwd $(id -u) >/dev/null; echo passwd_entry_rc=$?; "
            "sudo -n true >/dev/null 2>&1; echo sudo_n_rc=$?; "
            "su -c true root </dev/null >/dev/null 2>&1; echo su_rc=$?")
ROOT_FACTS = ("awk -F: '$1==\"root\"{c=substr($2,1,1); if (c==\"\") c=\"empty\"; "
              "print \"root_password_first_char=\" c}' /etc/shadow; "
              "cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | grep -Ev '^(#|Defaults|$)' "
              "| sed 's/^/sudoers: /'")


def sh(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True, timeout=120)


def exec_lines(name: str, user: str, script: str) -> dict[str, Any]:
    out = sh(["container", "exec", "--user", user, name, "sh", "-c", script])
    return {"rc": out.returncode, "lines": out.stdout.splitlines(), "stderr": out.stderr[-300:]}


def measure(image: str, shape: str, flags: list[str]) -> dict[str, Any]:
    name = f"masc-verify-{shape}-{image.split(':')[0].split('/')[-1]}-{int(time.time())}"
    argv = ["container", "run", "-d", "--rm", "--name", name, *flags,
            "--env", "HOME=/tmp", "--memory", "512m", "--cpus", "1", "--network", "none",
            "--entrypoint", "sleep", image, "infinity"]
    result: dict[str, Any] = {"image": image, "shape": shape, "argv": argv}
    ran = sh(argv)
    result["run_rc"] = ran.returncode
    if ran.returncode != 0:
        result["run_stderr"] = ran.stderr[-600:]
        return result
    try:
        config = json.loads(sh(["container", "inspect", name]).stdout)[0]["configuration"]
        env = config["initProcess"]["environment"]
        names = [entry.split("=", 1)[0] for entry in env]
        result["inspect_home_entries"] = [entry for entry in env if entry.split("=", 1)[0] == "HOME"]
        result["inspect_duplicate_names"] = sorted({n for n in names if names.count(n) > 1})
        for user in (KEEPER, "0:0"):
            result[f"exec_{user}"] = exec_lines(name, user, PROBE)
        result["escalation_as_keeper"] = exec_lines(name, KEEPER, ESCALATE)
        result["root_facts"] = exec_lines(name, "0:0", ROOT_FACTS)
        found = exec_lines(name, "0:0", "find / -xdev -perm -4000 -type f 2>/dev/null | sort")
        result["setuid_files"] = found["lines"]
    finally:
        result["stop_rc"] = sh(["container", "stop", name]).returncode
    return result


def main() -> None:
    results: dict[str, Any] = {"container_version": sh(["container", "--version"]).stdout.strip(),
                               "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                               "image_home": {}, "cases": []}
    for image in IMAGES:
        inspected = json.loads(sh(["container", "image", "inspect", image]).stdout)
        results["image_home"][image] = sorted(
            {entry for row in inspected for variant in row.get("variants", [])
             for entry in ((variant.get("config", {}).get("config") or {}).get("Env") or [])
             if entry.startswith("HOME=")})
        for shape, flags in (("agent", AGENT_FLAGS), ("exec", EXEC_FLAGS)):
            case = measure(image, shape, flags)
            results["cases"].append(case)
            print(json.dumps({k: v for k, v in case.items() if k not in ("argv", "setuid_files")})[:1800])
    with open(RESULTS, "w") as f:
        json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
