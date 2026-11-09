"""Run bench_server per (sink, cipher, write) and bench_client against it.

Sequential: REPS connections one after another. Parallel: 4 clients at once.
Server CPU per MB comes from the server's own process times around each
connection's writes. Prints one JSON object per configuration.
"""
import itertools
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "_build/default/bench_server.exe")
PY = sys.executable
PAYLOAD, N, REPS, PAR = 861_256, 60, 5, 4
SINKS = ["stock", "copy:16384", "copy:65536", "copy:262144", "copy:1048576"]
CIPHERS = ["aes128", "chacha"]
WRITES = [PAYLOAD, 65_536]


def run(port, sink, cipher, write):
    srv = subprocess.Popen([SERVER, str(port), f"{HERE}/cert.pem", f"{HERE}/key.pem", sink, cipher,
                            str(PAYLOAD), str(write)], stdout=subprocess.PIPE, text=True)
    assert json.loads(srv.stdout.readline())["ready"]
    client = [PY, f"{HERE}/bench_client.py", str(port), str(N)]
    seq = [json.loads(line) for line in
           subprocess.run(client + [str(REPS)], capture_output=True, text=True, check=True).stdout.splitlines()]
    seq_srv = [json.loads(srv.stdout.readline()) for _ in range(REPS)]
    procs = [subprocess.Popen(client + ["1"], stdout=subprocess.PIPE, text=True) for _ in range(PAR)]
    par = [json.loads(p.communicate()[0]) for p in procs]
    par_srv = [json.loads(srv.stdout.readline()) for _ in range(PAR)]
    srv.terminate()
    srv.wait()
    mb = PAYLOAD * N / 1e6
    seq_rate = sorted(c["mb_s"] for c in seq)[REPS // 2]
    seq_cpu = sorted((s["cpu_end"] - s["cpu_start"]) * 1e3 / mb for s in seq_srv)[REPS // 2]
    seq_client_cpu = sorted(c["client_cpu_s"] * 1e3 / mb for c in seq)[REPS // 2]
    span = max(s["wall_end"] for s in par_srv) - min(s["wall_start"] for s in par_srv)
    par_cpu = (max(s["cpu_end"] for s in par_srv) - min(s["cpu_start"] for s in par_srv)) * 1e3 / (mb * PAR)
    return {"sink": sink, "cipher": cipher, "write": write, "cipher_seen": seq[0]["cipher"],
            "seq_mb_s": seq_rate, "seq_server_ms_per_mb": round(seq_cpu, 2),
            "seq_client_ms_per_mb": round(seq_client_cpu, 2),
            "par4_total_mb_s": round(mb * PAR / span, 1), "par4_server_ms_per_mb": round(par_cpu, 2),
            "par4_server_busy": round(par_cpu * mb * PAR / 1e3 / span, 2)}


port = 19400
for write, cipher, sink in itertools.product(WRITES, CIPHERS, SINKS):
    port += 1
    print(json.dumps(run(port, sink, cipher, write)), flush=True)
