# Pacing storm fixture — 2026-07-06 nick0cave rotation ping-pong

RFC-0313 W0 artifact. Real production window demonstrating the failure
mode the pacing invariants forbid: rotation with zero revisit spacing
between two saturated runtimes.

## Contents

`nick0cave-rotation-0500-0504.csv` — one row per rotation retry:

```
ts,from_runtime,to_runtime,reason
```

## Facts this fixture pins

- Window: `2026-07-06T05:00:00Z` .. `05:04:59Z` (300 seconds).
- 2,004 rotation retries by a single keeper (~6.7/s sustained).
- Exactly 1,002 `runpod_rtxa6000.gemma4-coder-fable5-q4km -> glm-coding.glm-5-turbo`
  and 1,002 in the reverse direction: a pure two-runtime ping-pong where
  each saturated runtime's "failover" points at the other saturated one.
- 100% `reason=capacity_backpressure` — the provider was answering with
  a minutes-scale `retry_after` that the rotation loop did not consume.

Recount:

```sh
wc -l nick0cave-rotation-0500-0504.csv                 # 2004
cut -d, -f2,3 nick0cave-rotation-0500-0504.csv | sort | uniq -c   # 1002 / 1002
cut -d, -f4 nick0cave-rotation-0500-0504.csv | sort -u  # capacity_backpressure
```

## Provenance

Extracted from `<base-path>/.masc/logs/system_log_2026-07-06.jsonl` (84 MB,
not committed) with:

```sh
rg '"ts":"2026-07-06T05:0[0-4]:' system_log_2026-07-06.jsonl \
  | rg "nick0cave: recoverable runtime failure" \
  | rg -o '"ts":"([^"]+)".*failure in ([^;]+); rotation retry on runtime=([^ ]+) reason=([a-z_]+)' \
       -r '$1,$2,$3,$4'
```

The window is the densest 5 minutes of the 07-06 storm (15,254 retries
across 48h fleet-wide; this keeper alone produced 10,645).

## Consumers

- W0 (now): documentary evidence for `specs/keeper-state-machine/KeeperPacing.tla`
  — the `-buggy-unbounded` and clean models bound exactly the behavior
  recorded here.
- W3 (planned, RFC-0313): replay harness feeds these events through the
  pacing implementation and asserts (a) zero failure-driven existence
  changes, (b) per-keeper retry rate bounded by the pacing schedule
  (with a 30s base / x2 / 1h-cap revisit policy this window admits at
  most ~14 attempts per runtime, vs the 1,002 recorded), (c)
  `retry_after` honored within tolerance.
