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

## Mode B: keeper-load gate (`keeper_load_gate.sh`)

Mode A drives the main domain with serving load only; an idle (autoboot-disabled) boot has no
keeper compute, so its absolute regime is milder than production. Mode B seeds N declarative
keepers that run **real autonomous turns** against `mock_openai_provider.py` (network-free), then
probes `/health` while those keepers and optional host hogs contend for the one main Eio domain.

```bash
scripts/harness/perf/keeper_load_gate.sh --keepers 12 --levels "0 15" --probes 25
```

`mock_openai_provider.py` serves `POST /v1/chat/completions` in both non-streaming JSON (the
`backend_openai_request.ml` default `?(stream = false)` path) and SSE `chat.completion.chunk` modes
(`stream:true`), logging one JSON line per request so the gate counts provider calls = turns fired.

**The boot recipe (verified — keepers issue real turns; FSM reaches `awaiting_provider -> streaming`):**

1. **runtime.toml must borrow a catalog-valid model id.** `Runtime.init_default_strict`
   (`server_runtime_bootstrap.ml`) rejects any model whose `api-name` is absent from the OAS catalog
   (`oas-models.toml`). Set `api-name = "deepseek-v4-flash"` (a catalog `id_prefix`) while pointing
   the provider `endpoint` at the local mock.
2. **The keeper TOML must opt into autoboot.** Declarative keepers are excluded by design unless the
   `[keeper]` section sets `autoboot_enabled = true` (`keeper_runtime.ml:154`) **and**
   `proactive_enabled = true` (`keeper_activation_readiness.ml:16`, with `paused` false). A copied
   live config (e.g. `analyst.toml`, which ships `autoboot_enabled = false`) yields `0 keeper(s) to
   boot`.
3. **The keeper TOML must set `sandbox_profile = "local"`** (or `"docker"`) — boot rejects without it.
4. Boot env: `MASC_KEEPER_BOOTSTRAP_ENABLED=true`, `MASC_ORCHESTRATOR_ENABLED=1`,
   `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC=<n>`, `MASC_STORAGE_TYPE=filesystem`. Boot the exe directly —
   **not** via `harness_start_server`, which hardcodes the bootstrap off. (`MASC_AUTONOMY_ENABLED`
   does not exist in the code; the lib sets it as a harmless no-op.)
5. A persona directory must exist under `$BASE/.masc/config/personas/<persona_name>/`; the gate
   copies a real one (`analyst`) to avoid format guessing.

The gate refuses to report numbers if zero provider calls are seen during warmup (the mock wiring
is then broken), and it records a `turns_during` column per level.

**Known limitation (the gate self-warns):** keepers do an initial autoboot burst, then their
scheduled-autonomous cadence outruns the short `/health` probe window, so `turns_during` is
typically 0 at the measured levels — the measurement overlaps keepers *resident* but not *mid-turn*,
which is only marginally more faithful than Mode A. A GREEN verdict under that condition is weak and
the gate prints a `WARN` saying so. Two refinements make it bite: (1) drive **continuous** turns via
the reactive channel (inject board activity) rather than relying on the scheduled-autonomous cadence;
(2) have the mock return **large, realistic responses** (with tool calls) so the post-await parsing /
record-write / snapshot work — which is the real keeper main-domain cost, since the provider await
itself is I/O-bound and yields — actually loads the domain. `--mock-delay-ms` lengthens the await but
does not add main-domain CPU.

## Other limitations

- **`--inproc-load` hits a serving endpoint, not keeper compute.** It reproduces serving-domain
  head-of-line blocking, which is one real amplifier, but it is not identical to keeper-turn
  compute competing with serving. Until path (b) lands, the faithful keeper regime is only
  reachable via `--base-url` against the live MASC (where the real keepers run) plus host hogs.
- Run against the deploy host to capture the real concurrent-process load; the numbers above are
  from a developer box and are illustrative of the *shape*, not absolute production latency.

## What this harness has already caught

The `turn-records` cache+offload fix (a plausible RFC-0204 Phase 0 change mirroring the sibling
`/tool-stats` handler) was implemented, compiled, committed, then **reverted** when a controlled
two-binary A/B under this gate showed it does not reduce `/health` starvation (fixed ~17–21 ms vs
unfixed ~15–16 ms loaded p95, both RED). The dominant main-domain cost under load is response
serialization + gzip of the payload, which stays on main even on a cache hit; offloading only the
parse attacks a minor cost. See the revert commit for the full A/B. This is the gate doing its job:
falsifying a fix before it shipped.
