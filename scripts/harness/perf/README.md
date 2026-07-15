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

These predate the `LOAD_ACCEPT_ENCODING` default: load requests sent no `Accept-Encoding`, so the
server skipped compression. With the default `Accept-Encoding: zstd` (production-faithful) the
amplification rises to ~82× — see the json-offload falsification below. Compression on the main
domain makes starvation worse, not better.

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
Env-only: `LOAD_ACCEPT_ENCODING` (default `zstd` — load requests send `Accept-Encoding` so the
server runs its serialize+compress path as production browsers trigger; set empty for bare curl)
and `MASC_HARNESS_SERVER_EXE` (pin a specific binary so two builds can be A/B-compared without
overwriting `_build`).

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
# MASC_PERSONA_SOURCE_ROOT points at a populated MASC root (one with
# config/personas/<persona>); the gate copies that persona into its ephemeral
# base path. It is resolved from an explicit path, never home-anchored (SSOT-R6).
MASC_PERSONA_SOURCE_ROOT=<your-masc-root> \
  MOCK_REPLY_BYTES=150000 INJECT_INTERVAL=0.05 WARM_TURNS_SEC=30 \
  scripts/harness/perf/keeper_load_gate.sh --keepers 24 --levels "0 8" --probes 50
```

`MASC_PERSONA_SOURCE_ROOT` is the `.masc` dir that holds `config/personas/<persona>` (e.g.
`<root>/.masc`); the gate copies that persona into its ephemeral base path (resolved from an explicit
path, never home-anchored — SSOT-R6).

`mock_openai_provider.py` serves `POST /v1/chat/completions` in both non-streaming JSON (the
`backend_openai_request.ml` default `?(stream = false)` path) and SSE `chat.completion.chunk` modes
(`stream:true`), logging one JSON line per request so the gate counts provider calls = turns fired.

**The boot recipe (verified — keepers issue real turns; FSM reaches `awaiting_provider -> streaming`):**

1. **runtime.toml must borrow a catalog-valid model id.** `Runtime.init_default_strict`
   (`server_runtime_bootstrap.ml`) rejects any model whose `api-name` is absent from the OAS catalog
   (the OAS embedded catalog). Set `api-name = "deepseek-v4-flash"` (a catalog `id_prefix`) while pointing
   the provider `endpoint` at the local mock.
2. **The keeper TOML must opt into autoboot.** Declarative keepers are excluded by design unless the
   `[keeper]` section sets `autoboot_enabled = true` (`keeper_runtime.ml:154`) **and**
   `proactive_enabled = true` (`keeper_activation_readiness.ml:16`, with `paused` false). A copied
   live config (e.g. `analyst.toml`, which ships `autoboot_enabled = false`) yields `0 keeper(s) to
   boot`.
3. **The keeper TOML must set `sandbox_profile = "local"`** (or `"docker"`) — boot rejects without it.
4. Boot env: `MASC_KEEPER_BOOTSTRAP_ENABLED=true`, `MASC_ORCHESTRATOR_ENABLED=1`,
   `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC=<n>`. Boot the exe directly —
   **not** via `harness_start_server`, which hardcodes the bootstrap off. (`MASC_AUTONOMY_ENABLED`
   does not exist in the code; the lib sets it as a harmless no-op.)
5. A persona directory must exist under `$BASE/.masc/config/personas/<persona_name>/`; the gate
   copies a real one (`analyst`) to avoid format guessing.

The gate refuses to report numbers if zero provider calls are seen during warmup (the mock wiring
is then broken), and it records a `turns_during` column per level.

**Sustained-load (the original `turns_during=0` limitation, now resolved).** A first cut found
keepers did an autoboot burst then quiesced (load-generating keepers with "do minimal work"
instructions see no real work, so the autonomous cadence stops firing), leaving `turns_during=0`
during the probe window — a GREEN there was meaningless. Two changes make the keeper axis bite, and
the gate now reproduces RED on current main:

1. **Reactive board injection** (`REACTIVE_INJECT=1`, default): a background loop posts
   `masc_board_post` over `/mcp` @-mentioning a rotating keeper, driving the `Board_reactive` wake
   path (`keeper_world_observation_board_signal.ml`) so keepers keep turning instead of quiescing.
   This needs three things the harness now sets up: MCP auth is disabled for the ephemeral base path
   (`.masc/auth/config.json` `enabled:false` — `default_auth_config` is enabled+require_token, which
   otherwise 401s the injector); the `/mcp` transport is stateful, so the injector does the
   `initialize` → `Mcp-Session-Id` → `notifications/initialized` handshake and carries the session
   header; the session is acquired lazily and re-acquired on error (the booting fleet can saturate the
   server so the first `initialize` times out).
2. **Large mock replies** (`MOCK_REPLY_BYTES`): a keeper turn is I/O-bound (the provider await yields
   the main domain), so the real main-domain cost is *after* the await — parsing the response and
   writing the turn record. A trivial `"ack"` barely loads the domain even mid-turn; a large body
   (`--reply-bytes`) makes a resident keeper actually contend with serving.

**Measured (M3 Max 16-core, 2026-06-23, 24 keepers, 150 KB replies):** level 0 (keeper-burst, no
hogs) drove `/health` p95 to **~1.6 s** with `turns_during` 12; +8 host hogs ~0.8 s — both **RED**
(threshold 250 ms). Idle/light keeper load (16 keepers, 50 KB) stays GREEN (~1–24 ms), so the gate
discriminates. The RED is the merge gate for RFC-0204 Phase 3: keeper turns parsing/recording on the
single main Eio domain starve trivial serving, and a dedicated serving domain should flip it GREEN.
The gate still prints a `WARN` only if `turns_during` is genuinely 0 (injection inert).

Note: the Mode B verdict's amplification number is not meaningful (keepers run at every level, so
there is no idle in-run baseline); the RED criterion that bites is the **absolute** `loaded p95 >
THRESHOLD_MS`.

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

The `Response.json` / `json_value` **serialize + zstd-compress offload** (move the per-response
`Yojson.Safe.to_string` + `compress_body` off the main domain to the executor pool via
`submit_cpu_or_inline`, at the chokepoint every HTTP/1.1 JSON response passes through) was likewise
implemented, compiled, then **reverted**. A single 12-probe A/B looked promising at low host
contention (loaded `/health` p95 79→52 ms), but an interleaved 3-round A/B at the dominant axis
(48 in-process + 1 hog, 25 probes, `Accept-Encoding: zstd` sent so the production compress path
actually runs) found no reliable gain: unfixed loaded p95 {68.9, 70.9, 79.8} ms (mean 73), fixed
{42.9, 89.6, 76.9} ms (mean 70) — a −5% mean inside the noise band, with the fixed arm's variance
*wider* than unfixed. Same root as turn-records: the main domain still shepherds every one of the N
concurrent requests through accept → handler → submit → await → write, so offloading one sub-step
(serialize/compress) does not change that N requests serialize on one cooperative domain. Two
independent per-request micro-offloads are now refuted; the dominant axis is structural, not a
per-request cost.

(Surfacing this required a harness-fidelity fix: production browsers send `Accept-Encoding`, so the
server runs serialize+compress, but bare `curl` does not — without it `compress_body`
short-circuits and the gate underweights the cost. Sending it by default raised the measured
amplification from the earlier ~39–73× to ~82×, i.e. compression on the main domain makes the
starvation worse, not better.)

## Structural levers tested (gated by this harness, M3 Max 16-core)

Four candidate fixes for the starvation were tested **with the harness before shipping any
production code**, varying a knob and measuring rather than guessing. Three were refuted; one is a
partial mitigation.

| lever | how tested | result |
|---|---|---|
| **Offload `turn-records` compute** (cache + `submit_io_or_inline`) | two-binary A/B, real data | **refuted** — fixed ≈ unfixed, both RED (the parse is not the dominant cost) |
| **Offload `json` serialize + compress** (`submit_cpu_or_inline` at the `Response.json`/`json_value` chokepoint) | interleaved 3-round A/B, 48 inproc + 1 hog, 25 probes, `Accept-Encoding` on | **refuted** — unfixed loaded p95 mean 73 ms, fixed 70 ms (−5%, within noise); fixed-arm variance wider. Main domain still orchestrates all N requests (accept→handler→submit→await→write); offloading one sub-step doesn't unstarve it |
| **Reserve scheduler cores** (fewer worker domains) | sweep `MASC_EXECUTOR_DOMAIN_COUNT` ∈ {2,4,8,15} under 48 inproc + 15 hogs | **refuted (noise)** — a first sweep showed 15→8 halving amp (110×→43×), but an interleaved repeat found 15 ≈ 8 (amp 72–92× both); variance swamps the effect. Idle/blocked worker domains do not hold cores away from the main thread, so cutting them frees nothing |
| **OS priority / QoS** (deprioritize competing load) | one server, hogs at `nice 0` vs `nice 19`, 48 inproc both | **partial** — `nice 19` hogs cut amp 46× → 32× (~31%), but `/health` is still 120 ms (RED). The residual comes from the 48 normal-priority inproc requests, which QoS cannot touch |

**Conclusion the harness points to:** the dominant, irreducible axis is **serving concurrency
serialized on the single main Eio domain** — host contention (QoS-mitigable, ~31%) is secondary,
and every per-request micro-offload tried (parse; serialize + compress) was refuted because the
main domain still orchestrates all N requests. The only lever that addresses the dominant axis is
architectural: **RFC-0204 Phase 3 — a dedicated serving domain** so N concurrent requests are
handled off the main domain, leaving it for keepers + the scheduler. That is a large change
constrained by RFC-0059 (keepers are pinned to the main domain; only *serving* may move) and should
go through an RFC, validated by the Mode B keeper-load gate (whose sustained-load refinements have
landed and now reproduce the keeper-burst RED — the gate Phase 3 must flip GREEN).
launchd `ProcessType=Interactive` is a worthwhile but partial deployment-side mitigation.
