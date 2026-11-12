# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""Server CPU per MB sent, per TLS 1.3 suite, against an owned masc server.

Client: tls_client.py in a subprocess per run (homebrew Python, OpenSSL 3 on
arm64, suite fixed with OPENSSL_CONF). Server CPU: the process CPU time before
and after each run, minus the idle rate measured first. The clock is `ps -o
time` on macOS, in 0.01 s steps, and /proc/<pid>/stat on Linux, in steps of
1/SC_CLK_TCK s (0.01 s where SC_CLK_TCK is 100). The step read is kept in the
result as "cpu_clock_step_s". Linux `ps -o time` counts whole seconds, so one
step of it is 3.8 ms/MB at --n 300. Neither clock counts the CPU of child
processes of the server.
Each run: C parallel connections x N pipelined GETs of the dashboard bundle.
Every run's MB, wall time and server CPU are kept under "runs" in the result,
so a reader can see how many clock steps a median stands on.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

import httpx

SUITES = ("TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256")
CONF = """openssl_conf = default_conf
[default_conf]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
Ciphersuites = {suite}
"""


# Fields 14 (utime) and 15 (stime) of /proc/<pid>/stat, counted from the field
# after the command name. The name is in parentheses and may hold spaces and
# parentheses itself, so the fields are read after its last ")".
PROC_STAT_UTIME = 11
PROC_STAT_STIME = 12


def cpu_s_of_proc_stat(text: str, ticks_per_s: int) -> float:
    fields = text.rsplit(")", 1)[1].split()
    return (int(fields[PROC_STAT_UTIME]) + int(fields[PROC_STAT_STIME])) / ticks_per_s


# The last digit `ps -o time` prints on macOS.
MACOS_PS_TIME_STEP_S = 0.01


def cpu_clock_step_s() -> float:
    if sys.platform.startswith("linux"):
        return 1 / os.sysconf("SC_CLK_TCK")
    if sys.platform == "darwin":
        return MACOS_PS_TIME_STEP_S
    raise SystemExit(f"no process CPU clock known for platform {sys.platform}")


def cpu_s_of_ps_time(text: str) -> float:
    """macOS `ps -o time`: minutes:seconds.hundredths, with no hour or day field."""
    minutes, seconds = text.strip().split(":")
    return int(minutes) * 60 + float(seconds)


def cpu_s(pid: int) -> float:
    if sys.platform.startswith("linux"):
        return cpu_s_of_proc_stat(Path(f"/proc/{pid}/stat").read_text(), os.sysconf("SC_CLK_TCK"))
    if sys.platform == "darwin":
        return cpu_s_of_ps_time(
            subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True, check=True).stdout)
    raise SystemExit(f"no process CPU clock known for platform {sys.platform}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--assets", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--repeats", type=int, default=3)
    args = ap.parse_args()
    sys.path.insert(0, str(args.repo / "scripts/harness/perf"))
    import http_multiplex_probe as hmp

    here = Path(__file__).resolve().parent
    args.out.mkdir(parents=True, exist_ok=True)
    confs = {}
    for suite in SUITES:
        p = args.out / f"openssl-{suite}.cnf"
        p.write_text(CONF.format(suite=suite))
        confs[suite] = p
    bundles = sorted((args.assets / "dashboard/assets").glob("index-*.js"), key=lambda p: p.stat().st_size, reverse=True)
    result: dict = {"client": subprocess.run(["/opt/homebrew/bin/python3", "-c", "import ssl,sys; print(sys.version.split()[0], ssl.OPENSSL_VERSION)"], capture_output=True, text=True).stdout.strip()}
    with hmp.OwnedServer(args.binary, args.repo, args.out, None, args.assets) as server:
        pid = server.process.pid
        path = next(f"/dashboard/assets/{b.name}" for b in bundles
                    if httpx.get(f"{server.base_url}/dashboard/assets/{b.name}").status_code == 200)
        result["build"] = httpx.get(server.base_url + "/health").json()["build"]["commit"][:12]
        result["bundle_bytes"] = len(httpx.get(server.base_url + path).content)
        c0, t0 = cpu_s(pid), time.monotonic()
        time.sleep(10)
        idle = (cpu_s(pid) - c0) / (time.monotonic() - t0)
        result["idle_cpu_s_per_s"] = round(idle, 3)
        result["cpu_clock_step_s"] = cpu_clock_step_s()
        rows = {}
        for parallel in (1, 4):
            for mode in ("cleartext", *SUITES):
                runs = []
                for _ in range(args.repeats):
                    env = dict(os.environ)
                    port, kind = (server.port, "plain") if mode == "cleartext" else (server.https_port, "tls")
                    if mode != "cleartext":
                        env["OPENSSL_CONF"] = str(confs[mode])
                    c_before, w_before = cpu_s(pid), time.monotonic()
                    procs = [subprocess.Popen(["/opt/homebrew/bin/python3", "-I", str(here / "tls_client.py"), str(port), path,
                                               str(args.n), kind], env=env, stdout=subprocess.PIPE, text=True)
                             for _ in range(parallel)]
                    outs = [json.loads(p.communicate(timeout=300)[0]) for p in procs]
                    wall = time.monotonic() - w_before
                    cpu = cpu_s(pid) - c_before - idle * wall
                    mb = sum(o["bytes"] for o in outs) / 1e6
                    ciphers = sorted({str(o["cipher"]) for o in outs})
                    runs.append({"MB": mb, "wall_s": wall, "server_cpu_s": cpu, "ciphers": ciphers})
                rows[f"{mode} x{parallel}"] = {
                    "MB_s_median": round(statistics.median(r["MB"] / r["wall_s"] for r in runs), 1),
                    "server_cpu_ms_per_MB_median": round(statistics.median(1000 * r["server_cpu_s"] / r["MB"] for r in runs), 2),
                    "ciphers": runs[0]["ciphers"],
                    "runs": [{"MB": round(r["MB"], 2), "wall_s": round(r["wall_s"], 3),
                              "server_cpu_s": round(r["server_cpu_s"], 3)} for r in runs]}
                print(f"{mode} x{parallel}", rows[f"{mode} x{parallel}"], flush=True)
        result["rows"] = rows
    (args.out / "tls-cpu.json").write_text(json.dumps(result, indent=1) + "\n")
    print(json.dumps(result), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
