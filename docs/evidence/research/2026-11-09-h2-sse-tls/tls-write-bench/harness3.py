"""Run bench_server per (write, cipher, sink) and each client against it.

REPS connections one after another per client. Server CPU per MB comes from
the server's own process times around each connection's writes; client CPU
per MB from the client's own process times around its reads. Prints one JSON
object per (write, cipher, sink, client), medians over REPS.
"""
import itertools
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "_build/default/bench_server.exe")
CLIENTS = {"openssl": [sys.executable, f"{HERE}/bench_client.py"], "go": [f"{HERE}/bench_client_go"]}
PAYLOAD, N, REPS = 861_256, 60, 5
SINKS = ["stock", "pieces", "copy:16406", "copy:262144"]
CIPHERS = ["aes128", "chacha"]
# The whole body (HTTP/1.1), two HTTP/2 slices with their frame headers, one
# slice, and two slices cut to fit one TLS record each.
WRITES = [PAYLOAD, 32_786, 16_393, 32_750]


def median(values):
    return sorted(values)[len(values) // 2]


def run(port, sink, cipher, write):
    srv = subprocess.Popen([SERVER, str(port), f"{HERE}/cert.pem", f"{HERE}/key.pem", sink, cipher,
                            str(PAYLOAD), str(write)], stdout=subprocess.PIPE, text=True)
    assert json.loads(srv.stdout.readline())["ready"]
    mb = PAYLOAD * N / 1e6
    rows = []
    for name, argv in CLIENTS.items():
        out = subprocess.run(argv + [str(port), str(N), str(REPS)], capture_output=True, text=True, check=True)
        seen = [json.loads(line) for line in out.stdout.splitlines()]
        served = [json.loads(srv.stdout.readline()) for _ in range(REPS)]
        assert all(c["bytes"] == PAYLOAD * N for c in seen), seen
        server_ms = median([(s["cpu_end"] - s["cpu_start"]) * 1e3 / mb for s in served])
        client_ms = median([c["client_cpu_s"] * 1e3 / mb for c in seen])
        rows.append({"write": write, "cipher": cipher, "sink": sink, "client": name,
                     "cipher_seen": seen[0]["cipher"], "mb_s": round(median([c["mb_s"] for c in seen]), 1),
                     "server_ms_per_mb": round(server_ms, 2), "client_ms_per_mb": round(client_ms, 2),
                     "sum_ms_per_mb": round(server_ms + client_ms, 2)})
    srv.terminate()
    srv.wait()
    return rows


port = 19500
for write, cipher, sink in itertools.product(WRITES, CIPHERS, SINKS):
    port += 1
    for row in run(port, sink, cipher, write):
        print(json.dumps(row), flush=True)
