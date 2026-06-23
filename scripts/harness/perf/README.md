# Perf harness: main-domain scheduler starvation

`scheduler_starvation_gate.sh` turns the previously *observational* claim "MASC latency
tracks host load while `main_eio` sits at 12–27% CPU" (RFC-0204) into a **deterministic,
falsifiable measurement gate**.

## What it measures

MASC serves HTTP from a single main Eio domain that also carries every keeper fiber and the
refresh loops (`server_bootstrap_http.ml:157`, `keeper_keepalive.ml:650` — all `Eio.Fiber.fork ~sw`
on one switch). The harness probes a trivial endpoint (`/health`) while it puts that one domain
under load along two independent axes:

- **In-process load** (`--inproc-load N`): N background loops hammering a heavy endpoint
  (`/api/v1/dashboard/execution`), keeping the single serving domain busy.
- **Host CPU contention** (`--levels "…"`): N `yes` busy-loops competing with the main thread for
  OS timeslice.

For each level it runs `--probes` probes, records per-probe TTFB (`curl -w time_starttransfer`),
and reports p50 / p95 / max in ms plus timeout count.

## Measured results (origin/main `af959bfeff`, M3 Max 16-core, 2026-06-23)

| condition | `/health` p95 | amplification | verdict |
|---|---|---|---|
| baseline (idle) | ~1.1 ms | 1.0× | — |
| 16 host hogs, **idle server** | ~1.4 ms | 1.7× | GREEN |
| 1 host hog + 48 in-process | ~43 ms | ~39× | RED |
| 14 host hogs + 48 in-process | ~62–79 ms | ~56–73× | RED |

**Attribution (the load-bearing finding):** in-process serving concurrency is the dominant axis.
48 concurrent heavy requests on the one cooperative domain already drive `/health` to ~39× with
*negligible* host contention (1 hog). Host hogs are only a ~1.4× multiplier on top. An **idle**
server is barely sensitive to host hogs alone (1.7×) — the domain has nothing queued, so it is
scheduled promptly. Production starvation therefore requires the domain to be **busy** (keepers +
dashboard serving) *and* contended; "just inject CPU load" is not a faithful reproduction. This is
exactly the false premise Harness-First exists to catch before a fix is built on it.

## Gate semantics (falsifiable, per CLAUDE.md TLA+ bug-model discipline)

```
RED (exit 2)  if  loaded p95 > THRESHOLD_MS  OR  p95(loaded)/p95(baseline) > MAX_AMP
GREEN (exit 0) otherwise
ERROR (exit 1) on harness failure (server did not boot, missing tools)
```

The gate **must be RED on current main** under load — that failure is the proof it catches the
defect. A fix that flips it GREEN is validated; a gate that is GREEN on current main is too weak.

## Run

```bash
# self-contained (boots an ephemeral server using the canonical config/runtime.toml seed)
scripts/harness/perf/scheduler_starvation_gate.sh --levels "0 1 14" --inproc-load 48 --probes 12

# attach to an already-running server (e.g. the live runtime with real keepers busy)
scripts/harness/perf/scheduler_starvation_gate.sh --base-url http://127.0.0.1:8935 --levels "0 14"
```

Artifacts (`logs/perf-starvation/<run-id>/`): `levels.csv`, `summary.json`, per-level raw TTFB,
`server.log`. Knobs: `--endpoint`, `--probes`, `--levels`, `--inproc-load`, `--load-endpoint`,
`--threshold-ms`, `--max-amp`, `--base-url`, `--keep-server` (env equivalents mirror each flag).

The booted server runs with `MASC_AUTONOMY_ENABLED=0` (harness lib default): **no keepers run**, so
the in-process axis is the only "busy domain" source. To exercise the keeper axis, use `--base-url`
against a live runtime (see below).

## Which fix each axis validates

| axis the gate stresses | fix it can validate |
|---|---|
| in-process serving concurrency (dominant) | offload heavy-endpoint compute to the worker pool so the serving fiber only *awaits* (keeps the domain free for `/health`); RFC-0204 Phase 3 dedicated serving domain (separates serving from keepers) |
| host CPU contention (multiplier; needs a busy domain to bite) | launchd `ProcessType=Interactive` / QoS so `main_eio` wins timeslice; `domain_pool.ml` core-budget `recommended-2` to reserve a scheduler core |

Re-run the same command after a fix; the amplification should drop below `MAX_AMP`.

## Limitations / next iteration

- **No live keepers in boot mode.** The faithful keeper-vs-serving reproduction (RFC-0204 §5
  keeper-burst isolation) needs real keeper compute. Two paths: (a) `--base-url` against the live
  MASC where the 24 keepers are actually running, then add host hogs; (b) extend the harness to
  `MASC_AUTONOMY_ENABLED=1` + seeded keeper configs + a mock streaming provider. Path (b) is the
  committed-CI form and is the documented next step.
- **`--inproc-load` hits a serving endpoint, not keeper compute.** It reproduces serving-domain
  head-of-line blocking, which is one real amplifier, but it is not identical to keeper-turn
  compute competing with serving.
- Run against the deploy host to capture the real concurrent-process load; the numbers above are
  from a developer box and are illustrative of the *shape*, not absolute production latency.
