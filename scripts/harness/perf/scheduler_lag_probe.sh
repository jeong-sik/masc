#!/usr/bin/env bash
# scheduler_lag_probe.sh — read what one running masc server's main domain is doing.
#
# Three readings, nothing else:
#   1. /health time-to-last-byte over PROBES sequential requests (p50/p90/max).
#      This is what every TUI refresh pays before it can even parse a surface.
#   2. The server's own scheduler-lag ring from /health (.scheduler): how late a
#      ready fiber on the main domain ran over the last minute.
#   3. GC rates over RATE_WINDOW_S from two /health readings (.gc): minor and
#      major collections per minute and allocation MB/s.
#
# It is measurement, not a gate: it exits 0 whenever the server answered. Gates
# come after a baseline exists (docs/rfc/RFC-main-domain-scheduler-latency.md).
# It never builds or boots a server; point it at one with MASC_URL.
#
# Env: MASC_URL (default http://127.0.0.1:8935), PROBES (30), GAP_S (1),
#      RATE_WINDOW_S (10), CURL_MAX_S (30).

set -euo pipefail

URL="${MASC_URL:-http://127.0.0.1:8935}"
PROBES="${PROBES:-30}"
GAP_S="${GAP_S:-1}"
RATE_WINDOW_S="${RATE_WINDOW_S:-10}"
CURL_MAX_S="${CURL_MAX_S:-30}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need curl
need python3

health() { curl -s -m "$CURL_MAX_S" "$URL/health"; }

echo "== masc scheduler lag probe: $URL"
echo "-- /health latency over $PROBES probes (gap ${GAP_S}s)"
latencies="$(for _ in $(seq 1 "$PROBES"); do
  curl -s -m "$CURL_MAX_S" -o /dev/null -w '%{time_total}\n' "$URL/health" || echo "$CURL_MAX_S"
  sleep "$GAP_S"
done)"
python3 - "$latencies" << 'PY'
import sys
xs = sorted(float(x) for x in sys.argv[1].split())
n = len(xs)
def rank(p): return xs[max(0, min(n - 1, int(-(-p * n // 1)) - 1))]
print(f"   n={n} p50={rank(0.5):.3f}s p90={rank(0.9):.3f}s max={xs[-1]:.3f}s")
PY

echo "-- scheduler ring (.scheduler) and gc (.gc) from /health"
first="$(health)"
sleep "$RATE_WINDOW_S"
second="$(health)"
python3 - "$first" "$second" "$RATE_WINDOW_S" << 'PY'
import json, sys
a, b, dt = json.loads(sys.argv[1]), json.loads(sys.argv[2]), float(sys.argv[3])
s = b.get("scheduler")
if s is None:
    print("   scheduler: field absent (server predates the probe)")
else:
    keys = ["probe", "pool_domains", "samples", "p50_ms", "p95_ms", "p99_ms", "max_ms", "mean_ms", "stalls", "stopped_reason"]
    print("   scheduler: " + " ".join(f"{k}={s[k]}" for k in keys if k in s))
ga, gb = a.get("gc", {}), b.get("gc", {})
words = 8
def delta(k): return float(gb.get(k, 0)) - float(ga.get(k, 0))
if "minor_collections" in gb:
    alloc_words = delta("minor_words") + delta("major_words") - delta("promoted_words")
    print(f"   gc: minor/min={delta('minor_collections') * 60 / dt:.0f} major/min={delta('major_collections') * 60 / dt:.1f} "
          f"alloc_MB/s={alloc_words * words / 1048576 / dt:.1f} promoted_MB/s={delta('promoted_words') * words / 1048576 / dt:.1f} "
          f"heap_MB={float(gb.get('heap_words', 0)) * words / 1048576:.0f} live_MB={float(gb.get('live_words', 0)) * words / 1048576:.0f} "
          f"minor_heap_MB={float(gb.get('minor_heap_size', 0)) * words / 1048576:.0f} space_overhead={gb.get('space_overhead')}")
else:
    print(f"   gc: counters absent (server predates the probe); heap_words={gb.get('heap_words')} live_words={gb.get('live_words')}")
PY
