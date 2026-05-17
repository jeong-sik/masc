---
rfc: "0101"
title: "FD accountant — generic Eio.Pool extension to cover all spawn classes"
status: Active
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0098", "0099", "0100"]
implementation_prs: [15727, 15816]
---

# RFC-0101 — FD accountant: generic Eio.Pool extension across all spawn classes

Status: Active (prereq #15727 + PR-2 #15816 + PR-3 oas #1618 merged; PR-4/5/6 pending)
Author: jeong-sik (vincent)
Date: 2026-05-17
Scope: generic FD accountant that *extends* `Docker_spawn_throttle` ([[#15727]] merged) + `Keeper_fd_pressure` ([[#15727]]) into a multi-class pool covering provider HTTP, sandbox exec, log writer, and any other FD-bound spawn kind
Out of scope: docker-specific throttle policy (already merged as #15727), `kern.maxfiles` raise mechanics (covered by `launchd/masc-mcp-start.sh`), per-keeper sandbox container reuse ([[RFC-0097]] separate work)
Series: **IMPROVE-03** of the masc-mcp + oas improvement series. Sibling RFCs: [[RFC-0098]] / [[RFC-0099]] / [[RFC-0100]] / [[RFC-OAS-020]].

## 1. Problem

PR [[#15727]] (merged 2026-05-17) introduced `lib/docker_spawn_throttle.ml(i)` — a 2-layer cap (`Eio.Semaphore` + FD-pressure-aware mutex) on docker subprocess spawn. That fixes one spawn class — *docker run* — but the same FD-cost pressure applies to three other classes:

### 1.1 Provider HTTP clients open new TCP+TLS connections per call

`oas/lib/llm_provider/backend_anthropic.ml`, `backend_openai.ml`, etc. open a fresh `Eio.Net.with_tcp_connect` per LLM call. Each call = 1 TCP socket + TLS state. Under cascade-failure-storm (12+ keepers retrying simultaneously), this fan-out competes with docker for the same `kern.maxfiles` ceiling — the docker throttle alone doesn't bound it.

### 1.2 Sandbox / keeper bash exec spawns popen pipes

`lib/keeper/keeper_shell_bash.ml` + `lib/keeper/keeper_shell_docker.ml` spawn shells via popen / Eio.Process. Each spawn = stdin/stdout/stderr pipes + cgroup FD when inside docker. `#15727` Layer A bounds *docker run* but not the inner *exec* spawns that happen after the container is up (relevant to the RFC-0097 "container reuse" model where one container hosts many exec calls).

### 1.3 Log writers fan out

`Microlog`, `Log.Server`, dashboard SSE log streams, telemetry JSONL appends — each holds open one or more file FDs. Under sustained high-throughput logging, the cumulative FD cost has no accountant. There's no `/metrics` surface reporting `fd_open` / `fd_limit`.

The four spawn classes share one observable resource (`kern.maxfiles`) but have **four separate uncoordinated cost models**. The docker throttle from #15727 is the correct shape — a typed `with_slot` wrapper + `Keeper_fd_pressure` integration — but its *generalization to other spawn classes is missing*.

## 2. Non-goals

- **Replacing `Docker_spawn_throttle`.** This RFC *extends* it. The docker class becomes one of N classes on the generic accountant. The existing public API (`with_slot`, `effective_concurrency`) is preserved.
- **Replacing `Keeper_fd_pressure`.** The pressure-detection module continues to own the breaker state; the accountant *consumes* its signal across all classes (not just docker).
- **Per-keeper sandbox container reuse.** [[RFC-0097]] owns that; this RFC's accountant *measures* container-exec spawn cost regardless of which spawn model is in play.
- **Raising `kern.maxfiles`.** That's a system-config concern handled in `launchd/masc-mcp-start.sh`'s `sb_raise_nofile_limit`. This RFC adds *startup observability* (log whether the raise succeeded) but doesn't change the mechanism.
- **Replacing provider keep-alive plans.** [[RFC-0100]] composes with this RFC — keep-alive HTTP pooling reduces *cost per call*; this RFC bounds *concurrent call count*. Both are needed.

## 3. Design

### 3.1 Generic `Fd_accountant` module

New module `lib/server/fd_accountant.ml(i)`. Key signature:

```ocaml
type kind =
  | Docker_spawn
  | Provider_http
  | Sandbox_exec
  | Log_writer

val with_slot : kind:kind -> (unit -> 'a) -> 'a
(** Wraps an FD-consuming operation. Acquires a slot from the
    kind's [Eio.Pool], runs [f], releases. Same back-pressure
    semantics as [Docker_spawn_throttle.with_slot] but
    kind-discriminated.

    When [Keeper_fd_pressure.active ()] is true, ALL kinds
    serialize against a shared cool-down mutex (one-at-a-time
    globally during pressure). *)

val effective_concurrency : kind:kind -> int
val configured_concurrency : kind:kind -> int

val fd_snapshot : unit -> snapshot
(** Returns current FD usage by kind plus the system limit. *)

and snapshot = {
  per_kind : (kind * int) list ;  (* in-flight count per class *)
  fd_open  : int ;                (* libc rlimit observation *)
  fd_limit : int ;                (* RLIMIT_NOFILE soft cap *)
  pressure_active : bool ;
}
```

Caps per kind (env-overridable):

| Kind | Default | Env var |
|---|---|---|
| `Docker_spawn` | 8 | `MASC_DOCKER_SPAWN_CONCURRENCY` (existing, preserved) |
| `Provider_http` | 16 | `MASC_PROVIDER_HTTP_CONCURRENCY` |
| `Sandbox_exec` | 32 | `MASC_SANDBOX_EXEC_CONCURRENCY` |
| `Log_writer` | 64 | `MASC_LOG_WRITER_CONCURRENCY` |

Defaults sum (8+16+32+64 = 120) is intentionally well below the assumed `kern.maxfiles=491_520` ceiling and below the per-process soft cap (typically 10_240). Pressure breaker kicks in earlier than ceiling exhaustion.

### 3.2 `Docker_spawn_throttle` delegation

`lib/docker_spawn_throttle.ml` becomes a thin delegate:

```ocaml
let with_slot f = Fd_accountant.with_slot ~kind:Docker_spawn f
let effective_concurrency () = Fd_accountant.effective_concurrency ~kind:Docker_spawn
```

Public API preserved — callers don't change. This is RFC-0098 PR-2's pattern (delegate-then-deprecate) reapplied at the FD layer.

### 3.3 Provider HTTP wrap

`oas/lib/llm_provider/backend_*.ml` HTTP clients gain a tiny wrapper:

```ocaml
let with_http_call f =
  Fd_accountant.with_slot ~kind:Provider_http (fun () ->
    Eio.Net.with_tcp_connect ~service flow f)
```

This is a small additive change — one wrap per backend file. PR-3 of the migration.

Long-term: combine with [[RFC-0100]]'s keep-alive pool (one TLS connection per provider, reused across calls). Until that lands, per-call wrapping bounds concurrent count even without keep-alive.

### 3.4 `/metrics` Prometheus exposure

`Fd_accountant.fd_snapshot ()` is wired into the existing Prometheus export. New metric series:

```
masc_fd_open                                          gauge
masc_fd_limit                                         gauge
masc_fd_in_flight{kind="docker_spawn"}                gauge
masc_fd_in_flight{kind="provider_http"}               gauge
masc_fd_in_flight{kind="sandbox_exec"}                gauge
masc_fd_in_flight{kind="log_writer"}                  gauge
masc_fd_pressure_active                               gauge (0/1)
masc_fd_pressure_transitions_total{from="...",to="..."} counter
```

Dashboard `System Health` panel consumes. Operator sees per-kind cost without inferring from `lsof`.

### 3.5 Startup nofile-limit log

`lib/server/fd_accountant.ml` init logs once at startup:

```
fd-accountant: rlimit_nofile soft=10240 hard=10240 (launchd raise: success/fail)
fd-accountant: configured caps docker=8 provider_http=16 sandbox_exec=32 log_writer=64 (sum=120)
```

If sum-of-caps approaches the soft limit (within 50 % headroom), startup logs a WARN. Operator can either raise the limit (`launchd` path) or lower the caps (env vars).

### 3.6 Compose with RFC-0099 backpressure

When `pressure_active = true` for >5 seconds, `Fd_accountant` publishes an evict signal on the session lifecycle bus ([[RFC-0099]]):

```
Session_lifecycle_event.Evict { transport = SSE ; session_id = <oldest> ; reason = Backpressure }
```

This couples FD pressure → session shedding. The 5-second debounce avoids flapping during transient spikes.

## 4. Migration plan

| PR | Scope | Acceptance |
|----|-------|-----------|
| PR-1 (this) | RFC body | review + merge |
| PR-2 | `lib/server/fd_accountant.ml(i)` + 4-kind Eio.Pool + `Docker_spawn_throttle` delegation. Inert: docker behavior unchanged. | `test_fd_accountant.ml` 256-connection round-trip; existing docker spawn tests unchanged |
| PR-3 | Provider HTTP wrap in `oas/lib/llm_provider/backend_*.ml` (small cross-repo PR pair) | benchmark: pressure-during-cascade-storm holds `Provider_http` count ≤ 16 |
| PR-4 | Sandbox exec wrap (`keeper_shell_*.ml`) + log writer wrap (largest writers only). | `Sandbox_exec` and `Log_writer` series visible in Prometheus dashboard |
| PR-5 | `/metrics` exposure + dashboard panel + startup nofile log | operator can see snapshot via `curl /metrics \| grep masc_fd_` |
| PR-6 | RFC-0099 Backpressure evict signal compose | pressure → evict observable in `Session_lifecycle_event` stream |

PR-2 is **wire-inert** (docker behavior preserved via delegation). PR-3 onward observably bounds cost; risk is per-PR small.

## 5. Verification

- `test/test_fd_accountant.ml`: 4-kind pool unit tests — uniqueness of slots, exception-release, FD-pressure serialization.
- `scripts/harness/fd_saturation.sh` (new): drive 64 concurrent provider HTTP calls; assert `Provider_http` count never exceeds configured cap.
- `scripts/harness/fd_regression_issue_13642.sh` (new): reproduce the symptom shape of past issue #13642 ("runtime refuses new loopback connections while listen socket remains open under keeper saturation") and assert that the typed FD pressure signal fires *before* connection refusal.
- Soak (6-hour): `masc_fd_open` series + per-kind series stay within configured caps; no `pressure_active` flap (transitions < 10).
- `bash scripts/check-doc-truth.sh`: 4 env vars match `Env_config_*` exports.

## 6. Trade-offs

| For | Against |
|-----|---------|
| Generic accountant covers all spawn classes — `kern.maxfiles` exhaustion has one chokepoint, not four. | Migration touches 4 areas (docker / provider HTTP / sandbox exec / log writers). 5-PR sequence. |
| Preserves `Docker_spawn_throttle` public API — delegation pattern matches RFC-0098 PR-2 precedent. | Adds one layer of indirection for docker callers; negligible overhead, but worth noting. |
| `/metrics` exposure ends the "observable resource without observability" gap. | Adds 7 new metric series — Prometheus card-cost grows; well within budget. |
| Compose cleanly with [[RFC-0099]] (Backpressure evict) and [[RFC-0100]] (HTTP keep-alive reduces per-call cost). | Hard dependency: RFC-0099 PR-3 must be present for §3.6 evict-on-pressure. If RFC-0099 stalls, PR-6 of this RFC stalls. |
| Per-kind cap tuning is env-controlled — operators can lower if their environment has tighter FD limits. | Operators must understand 4 separate caps + their interaction. Default mix (120 sum) is the recommended pre-tuning state. |

## 7. Open questions

- **Q1**: Should `Log_writer` cap be per-instance (each writer 1 FD) or shared (sum across writers)? **Decision (default)**: shared cap (count of in-flight log-write operations, not file handles). Per-instance accounting is operator-confusing.
- **Q2**: Provider HTTP wrap — should it be inside `oas/lib/llm_provider/backend_*` (consumer-internal) or at the masc-mcp boundary (cdal_runtime call site)? **Open** — PR-3 picks based on which has cleaner ownership.
- **Q3**: `Log_writer` migration is the trickiest (every `Log.*` call). Should PR-4 wrap only the highest-throughput writers (dashboard SSE log stream, telemetry JSONL) and leave `Log.warn`/`Log.error` unwrapped? **Decision (default)**: yes — high-throughput writers only. The low-throughput `Log.warn` path is FD-cost negligible.

## 8. Acceptance

- [x] **Prereq** (#15727): `Docker_spawn_throttle` Layer A (per-class semaphore) + Layer B (`Keeper_fd_pressure`-aware mutex) — the docker-only ancestor this RFC extends.
- [x] **PR-1** (#15803): RFC body merged.
- [x] **PR-2** (#15816): `lib/server/fd_accountant.ml(i)` 4-kind generic pool (`Docker_spawn` / `Provider_http` / `Sandbox_exec` / `Log_writer`) + `Docker_spawn_throttle.with_slot` delegation (public API preserved, wire-inert) — 8 tests including cap-bounds fan-in.
- [x] **PR-3** (oas #1618): provider HTTP wrap via dependency-injection hook (`Fd_throttle_hook` in oas + `Provider_throttle.with_permit_priority` composes), since oas cannot depend on masc-mcp directly. RFC §3.3 originally specified direct `Fd_accountant` call from `backend_*.ml`; DI pattern replaces that. Embedder (masc-mcp) wires `Fd_throttle_hook.set_handler (fun thunk -> Fd_accountant.with_slot ~kind:Provider_http thunk)` at bootstrap (follow-up commit, not in PR-3 itself).
- [ ] **PR-4**: sandbox exec wrap (`keeper_shell_*.ml`) + log writer wrap (largest writers only).
- [ ] **PR-5**: `Fd_accountant.fd_snapshot` → Prometheus `/metrics` + dashboard `System Health` panel + startup nofile-limit log.
- [ ] **PR-6**: compose with [[RFC-0099]] `Backpressure` evict signal — `pressure_active = true > 5 s` → `Session_lifecycle_event.Evict { reason = Backpressure }` publish.
- [x] **Status promoted to `Active`** at PR-2 merge (this closeout commit). `Implemented` promotion deferred until PR-5 (operator-visibility surface) at minimum. The wire-up commit on the masc-mcp side that calls `Fd_throttle_hook.set_handler` is intentionally separated from this closeout and tracked as a follow-up.

## 9. References

- PR [[#15727]] — `Docker_spawn_throttle` foundation (merged, this RFC extends)
- Issue [[#13642]] — listen-socket refuses-loopback symptom (FD exhaustion class)
- [[RFC-0097]] — Keeper sandbox container reuse (parallel work, reduces sandbox spawn rate)
- [[RFC-0098]] — Typed JSON-RPC error envelope (`Backpressure_shed` -32005 wire code consumes FD signal)
- [[RFC-0099]] — Session lifecycle typed events (Backpressure evict_reason)
- [[RFC-0100]] — Streamable HTTP (HTTP keep-alive pool reduces per-call cost)
- [Eio.Pool](https://ocaml-multicore.github.io/eio/eio/Eio/Pool/index.html)
- [Eio.Semaphore](https://ocaml-multicore.github.io/eio/eio/Eio/Semaphore/index.html)
