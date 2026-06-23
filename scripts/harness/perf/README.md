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

## Keeper-load injection (WIP — provider mock done, autoboot wiring pending)

`mock_openai_provider.py` is a network-free OpenAI-compatible provider for driving real keeper
turns in a boot harness, so the gate can reproduce the faithful keeper-vs-serving contention
(RFC-0204 §5) instead of the milder serving-only regime an idle (autoboot-disabled) boot produces.
It serves `POST /v1/chat/completions` in both modes: non-streaming JSON (the
`backend_openai_request.ml` default `?(stream = false)` path) and SSE `chat.completion.chunk`
frames when the request sets `stream:true`. Every request is logged one-JSON-line to `--log` so a
harness can count provider calls = turns fired.

```bash
python3 scripts/harness/perf/mock_openai_provider.py --port 8899 --log /tmp/mock.jsonl --delay-ms 0
```

**What is verified to work:** the server boots against this mock with a runtime.toml that routes a
catalog-valid model id to the mock endpoint. `Runtime.init_default_strict` (the OAS capability
gate, `server_runtime_bootstrap.ml`) rejects any model whose `api-name` is not in the OAS catalog
(`oas-models.toml`), so the runtime.toml must **borrow a real catalog id** while pointing its
provider at the mock:

```toml
[runtime]
default = "mock.mockmodel"
[providers.mock]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:8899"
[models.mockmodel]
api-name = "deepseek-v4-flash"   # must be an oas-models.toml id_prefix
[models.mockmodel.capabilities]
supports-native-streaming = true
[mock.mockmodel]
is-default = true
```

Boot env (note: do **not** use `harness_start_server`, which hardcodes the bootstrap off; boot the
exe directly): `MASC_KEEPER_BOOTSTRAP_ENABLED=true`, `MASC_ORCHESTRATOR_ENABLED=1`,
`MASC_KEEPER_HEARTBEAT_INTERVAL_SEC=5`, `MASC_STORAGE_TYPE=filesystem`, plus a keeper TOML under
`$BASE/.masc/config/keepers/` and a persona dir under `$BASE/.masc/config/personas/`.

**The remaining blocker (the documented next step):** declarative (config-TOML) keepers are
excluded from autoboot by design — `keeper_runtime.ml:154 autoboot_exclusion_reason` returns
`declarative_autoboot_disabled` unless the keeper profile sets `autoboot_enabled = true`, and
`keeper_activation_readiness.ml:16` also requires `proactive.enabled = true` and `paused = false`.
A copied live keeper config (e.g. `analyst.toml`) boots the server but yields `0 keeper(s) to boot`
for this reason. Finishing path (b) means: (1) author a keeper TOML with `autoboot_enabled` /
`proactive_enabled` set (field parsed under `lib/keeper/` `profile_defaults_for_config`), (2)
confirm a turn actually issues a provider call (the mock log goes non-empty), then (3) wire a
`--with-keepers` mode into the gate that starts the mock, seeds configs, and boots with the env
above. This was stopped at the 3-Try boundary after the gate/boot succeeded but autoboot stayed
disabled; it is a bounded two-flag fix plus a work-discovery liveness check, not a new approach.

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
