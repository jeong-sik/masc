"""Measure only the pure scoring derivation on the retained X2 fixture."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import runpy
import statistics
import time

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixtures/046-01-48-X2.json"
BYTES = FIXTURE.read_bytes()
OBSERVATION = json.loads(BYTES)["observations"][0]
DERIVE = runpy.run_path(str(HERE / "server.py"))["derive"]

for _ in range(100):
    DERIVE(OBSERVATION)
times = []
for _ in range(1000):
    started = time.perf_counter_ns()
    result = DERIVE(OBSERVATION)
    times.append(time.perf_counter_ns() - started)
times.sort()
print(json.dumps({
    "fixture_sha256": hashlib.sha256(BYTES).hexdigest(),
    "fixture_bytes": len(BYTES),
    "pbp_rows": len(OBSERVATION["rows"]),
    "warmups": 100,
    "iterations": len(times),
    "median_us": round(statistics.median(times) / 1000, 2),
    "p95_us": round(times[949] / 1000, 2),
    "result": result,
}, ensure_ascii=False))
