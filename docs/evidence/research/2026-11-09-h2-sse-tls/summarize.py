"""Summarize a leak-probe run: counters at each point, then deltas against the warm sample."""
import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
rows = [json.loads(line) for line in (run / "samples.jsonl").read_text().splitlines() if line.strip()]
keys = ["live_mb", "heap_mb", "rss_mb", "fds", "tcp_fds", "http_active", "https_active", "sse_clients", "tls_handshake_failures", "major"]
print("| point | t s | " + " | ".join(keys) + " |")
print("|---" * (len(keys) + 2) + "|")
for r in rows:
    print(f"| {r['label']} | {r['t_s']} | " + " | ".join(str(r.get(k)) for k in keys) + " |")
warm = next(r for r in rows if r["label"] == "warm")
print("\ndeltas against warm:")
for r in rows:
    if r["label"] in ("cold", "warm"):
        continue
    d = {k: round(r[k] - warm[k], 1) for k in ("live_mb", "rss_mb", "fds", "tcp_fds", "https_active", "http_active", "sse_clients")}
    print(f"  {r['label']}: {d}")
runs = run / "runs.json"
if runs.exists():
    print("\nruns:")
    for item in json.loads(runs.read_text())["runs"]:
        print("  " + json.dumps(item)[:600])
