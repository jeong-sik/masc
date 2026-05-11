# RFC-0070: Keeper Sandbox Runtime — Pure/Edge Separation

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7, /loop iterations 1-5)
- **Created**: 2026-05-12
- **Depends on**: RFC-0036 Phase A (cleanup hook plumbing — foundation)
- **Extends**: RFC-0006 Phase B-2 (Read/Edit/Grep docker exec routing)
- **Related**: RFC-0002 (keeper FSM), RFC-0003 (composite lifecycle observer)
- **Drives**: closes F1-F7 below; resolves CLAUDE.md §AI 안티패턴 #4 violation in `keeper_sandbox_control.ml`

## 1. Problem

The keeper sandbox subsystem currently mixes three concerns in two large files (`keeper_sandbox_runtime.ml` 33 KB, `keeper_shell_docker.ml` 40 KB):
1. **Pure command/arg construction** (deterministic in principle)
2. **Docker daemon I/O** (non-deterministic, fragile string parsing)
3. **Wall-clock ID generation** (non-deterministic mid-construction)

The resulting failure modes (catalogued during `/loop` iterations 1-2 against `lib/keeper/` HEAD):

| # | Symptom | Site | Severity |
|---|---------|------|----------|
| F1 | `container_name` derived from `Unix.gettimeofday()*1000` — collision possible under concurrent keepers | `keeper_sandbox_control.ml:38`, `keeper_shell_docker.ml:66`, `keeper_turn_sandbox_runtime.ml:58` | HIGH |
| F2 | `still_exists()` returns `false` when docker daemon unavailable → container orphan, cleanup believes "already gone" | `keeper_turn_sandbox_runtime.ml:413-446` | HIGH |
| F3 | `docker ps -a` substring parsing — output format changes between docker 24.x/25.x silently break the gate | `keeper_sandbox_runtime.ml:562, 643-674` | MEDIUM |
| F4 | 5s minimum timeout floor as a magic literal — first-turn image pull can exceed | `keeper_shell_docker.ml:640` | MEDIUM |
| F5 | `Unix.kill(pid, 0)` liveness check races on PID reuse — dead owner false-positive | `keeper_sandbox_runtime.ml:477-499` | MEDIUM |
| F6 | 8× `try ... with _ -> None` in git/probe paths — any failure becomes "not found", reason lost | `keeper_sandbox_control.ml:261-308` | MEDIUM |
| F7 | Cleanup loop increments `metric_keeper_turn_cleanup_failures` counter and returns empty — no retry, no escalation | `keeper_turn_sandbox_runtime.ml:466-468`, `keeper_sandbox_runtime.ml:618-625` | HIGH (CLAUDE.md §워크어라운드 §1 — counter-as-fix) |

F1, F3, F6 are direct instances of CLAUDE.md §AI 코드 생성 안티패턴: hardcoded scattered (#1), unknown→permissive default (#2), `_ -> None` catch-all (#4). F7 trips the §워크어라운드 거부 §1 — telemetry-as-fix.

## 2. Goals / Non-Goals

**Goals**
- **G1** *Deterministic ID*: `container_name = pure_fn(turn_id, attempt, suffix)`. Same input → same output. Wall-clock removed from the construction path.
- **G2** *Typed daemon errors*: every docker daemon call returns `(_, sandbox_error) result` where `sandbox_error` is a closed sum (`Daemon_unreachable | Image_pull_failed | Container_oom | Exec_timeout | Probe_format_drift | Cleanup_failed`). No catch-all.
- **G3** *JSON-format docker probe*: `docker ps --format '{{json .}}'` + `ppx_deriving_yojson` typed schema replaces substring parsing. Docker version detected once and recorded as a `Docker_version.t` variant.
- **G4** *Cleanup as state machine, not counter*: replace counter-as-fix with `cleanup_outcome = Clean_success | Clean_partial | Clean_quarantine` and quarantine retry+alert path.
- **G5** *Mock-able executor*: introduce `Docker_client.t` module type, with real and mock implementations, enabling property-seeded replay tests.

**Non-Goals**
- *Multi-container topology* — RFC-0036 territory. This RFC is single-container-aware; container-per-keeper layout layer is orthogonal.
- *New sandbox profiles* — RFC-0006 territory. `Local | Docker` variants stay as-is.
- *Cleanup hook surface change* — RFC-0036 §3.1 defines `cleanup_hook : keeper_id -> cleanup_event -> unit`, synchronous best-effort non-throwing. This RFC's `cleanup_outcome` is the *internal* Result.t form; an adapter wraps it into the public hook (log + swallow).
- *`Keeper_sandbox.t` public surface change* — the existing closed record + `of_meta` + `Keeper_sandbox_factory.resolve` (introduced 2026-05-11) are preserved unmodified.

## 3. Design

### 3.1 Pure core (Sandbox_plan)

```ocaml
(* lib/keeper/keeper_sandbox_plan.mli *)
type t = private {
  container_name  : Container_name.t;
  image_pin       : Image.digest;          (* sha256:..., NOT a tag *)
  mounts          : Mount.t list;
  env_passthrough : (string * string) list;
  ulimits         : Ulimit.t list;
  network_mode    : Network.t;
  timeout_budget  : Eio.Time.span;
}

val of_request
  : turn_id:Turn_id.t
    -> attempt:int
    -> meta:Keeper_types.keeper_meta
    -> cmd:Cmd.t
    -> (t, Plan_error.t) result

(* Same input ⇒ identical plan. No Random, no Unix.time. *)
```

`Container_name.t` is a private string derived as `"masc-keeper-" ^ base36(BLAKE3(turn_id ‖ attempt ‖ suffix)[..16])`. Collision space 1/2^96. Test backdoor `Container_name.of_string_for_test` is exposed only under `let%test_module` and not in the public `.mli`.

### 3.2 Edge layer (Docker_client + Sandbox_executor)

```ocaml
(* lib/keeper/docker_client.mli *)
module type S = sig
  val run         : Sandbox_plan.t -> (Exec_result.t, sandbox_error) result
  val exec        : container:Container_name.t -> cmd:Cmd.t -> (Exec_result.t, sandbox_error) result
  val ps_query    : labels:(string * string) list -> (Ps_record.t list, sandbox_error) result
  val rm          : Container_name.t -> (unit, sandbox_error) result
end

module Real : S    (* spawns real docker via Eio.Process *)
module Mock : sig
  include S
  val inject_response : Sandbox_plan.t -> (Exec_result.t, sandbox_error) result -> unit
  val inject_ps_latency : Eio.Time.span -> unit
end
```

`Sandbox_executor` consumes a `Sandbox_plan.t` and a `Docker_client.S` instance; returns `Result.t`. The current `keeper_sandbox_runtime.ml` / `keeper_shell_docker.ml` callers cut over to `Sandbox_executor.run` in Phase 4 (see §4).

### 3.3 Typed docker probe

```ocaml
(* lib/keeper/ps_record.mli *)
type ps_status =
  | Running
  | Created
  | Exited of { code : int }
  | Paused
  | Dead
  | Restarting
[@@deriving yojson, show, eq]

type t = {
  id         : Container_id.t;
  name       : Container_name.t;
  status     : ps_status;
  labels     : (string * string) list;
  created_at : Mtime.t;                     (* Mtime, not Unix.gettimeofday *)
}
[@@deriving yojson, show, eq]
```

Underlying call: `docker ps --format '{{json .}}' --filter label=...`. JSON line-delimited, parsed via `ppx_deriving_yojson`. `Probe_format_drift` error fired if a record fails to parse — caller sees a typed alert, not a silent miss.

### 3.4 Cleanup quarantine state machine

```ocaml
type cleanup_outcome =
  | Clean_success    of { removed : Container_name.t list }
  | Clean_partial    of {
      removed   : Container_name.t list;
      failed    : (Container_name.t * sandbox_error) list;
    }
  | Clean_quarantine of {
      stuck             : Container_name.t list;
      attempts          : int;
      alert_dispatched  : bool;
    }

val cleanup_tick
  : sw:Eio.Switch.t -> clock:#Eio.Time.clock
    -> docker:(module Docker_client.S)
    -> quarantine:Quarantine.t
    -> cleanup_outcome
```

`Quarantine.t` is a per-server-session Set of `(Container_name.t, retry_attempts:int, first_seen:Mtime.t)`. Three retry attempts with exponential backoff; on the 4th tick, `alert_dispatched` becomes true and an operator alert fires (separate from the existing Prometheus counter, which becomes a *by-product*, not the decision mechanism). The cleanup hook adapter for RFC-0036 §3.1 wraps `cleanup_outcome` into a `unit` via log-and-swallow.

### 3.5 Containment with existing modules

| Existing | Role in this RFC |
|----------|------------------|
| `Keeper_sandbox.t` (closed record, `of_meta`) | Input to `Sandbox_plan.of_request` — preserved unchanged |
| `Keeper_sandbox_factory.resolve` (memoized per `(in_playground, network_mode)`) | Calls into `Sandbox_executor` in Phase 4 — wiring change only |
| `Keeper_sandbox_containment.check_{read,write}_target` (RFC-0006 Phase B-1) | Continues as host-side defense-in-depth — unchanged |
| RFC-0036 `cleanup_hook` | Registers `Sandbox_cleanup.adapter` that wraps `cleanup_outcome` |

## 4. Migration

| Phase | Deliverable | RFC dependency | Risk |
|-------|-------------|----------------|------|
| **0** | `pr-rfc-check.sh` sandbox patterns + bash 3.2 compat | none | done in `~/me`@`d0add960d7` |
| **1** | `keeper_sandbox_plan.mli` + `docker_client.mli` (signatures, empty stubs) | none | LOW — no runtime change |
| **2** | Plan + Real Docker_client implementations, existing callers unchanged | Phase 1 | LOW — both paths coexist |
| **3** | `Sandbox_executor` + `Sandbox_cleanup` + `Docker_client.Mock` + property tests | Phase 2, RFC-0036 Phase A | MEDIUM — first behavior coexistence |
| **4** | Caller cutover (one site per PR): `keeper_shell_docker` / `keeper_sandbox_runtime` / `keeper_turn_sandbox_runtime` → `Sandbox_executor.run` | Phase 3 | MEDIUM — caller surface preserved by `Sandbox_executor` wrapper |
| **5** | Catch-all removal: delete the 8 `try ... with _ -> None` sites in `keeper_sandbox_control.ml`; compiler enforces caller migration | Phase 4 | LOW — compiler is the migration check |

Phases 1-5 are independently mergeable and revertable. Phase 5 closes the loop by making the old anti-pattern syntactically unwritable in this subsystem.

## 5. Validation

- **Phase 1**: alcotest for type-only signatures (parse + emit JSON for `Sandbox_plan.t` and `Ps_record.t`).
- **Phase 2**: `Sandbox_plan.of_request` property test (qcheck) — `∀ (turn_id, attempt, meta), of_request → Ok` (no panic, no Random). Same input twice → identical plan.
- **Phase 3**: `Docker_client.Mock` driven tests:
  - Daemon-unreachable response → `Daemon_unreachable` propagates to caller, no silent fail.
  - `ps_query` malformed JSON → `Probe_format_drift` typed error.
  - Cleanup loop with 3-fail-then-success → `Clean_quarantine` → `Clean_partial` → `Clean_success` sequence.
- **Phase 4**: integration test running a real `Sandbox_executor.run` end-to-end against a local docker daemon, side-by-side with the legacy path for one keeper persona.
- **Phase 5**: `rg "try.*with _ -> None" lib/keeper/keeper_sandbox_control.ml` returns zero hits.

## 6. Risks

| Risk | Mitigation |
|------|------------|
| dune dep cascade — Phase 2 adds 2 new sub-libs (`keeper_sandbox_plan`, `docker_client`). MEMORY `feedback_rfc_oas_011_cdal_runtime_admin_merge_cascade` documented a 4-PR cascade pattern when dep closure underverified. | Single PR per Phase 1 / 2 / 3; verify `dune build --root . @check` *before* push; defer caller cutover until Phase 4 (no cascade until then) |
| Alert flood from quarantine path | Alert dedup TTL: same `Container_name.t` quarantine event suppresses re-alert within 1h. Recorded in `Quarantine.t` state. |
| Mock vs real daemon divergence | Phase 4 integration test runs both paths; mock impl reviewed against `docker --version` output diff suite. |
| RFC-0036 cleanup hook *non-throwing* contract vs this RFC's Result.t *escalating* contract | `Sandbox_cleanup.adapter` wraps internal Result.t into the public hook (`log + swallow`). Public hook contract preserved. Internal logic retains typed errors. |
| BLAKE3 dependency in OCaml — current opam constraints | Phase 1 chooses between `blake3` (current pin), `digestif` (already present), or `Mirage_crypto.Hash`. Decision tracked in Phase 1 PR; fallback is `Mirage_crypto.Hash.SHA256.digest` if BLAKE3 unavailable on target opam switch. |

## 7. Out of Scope (v2 candidates)

- Docker socket multiplexing for fleet (multi-host scaling)
- BuildKit cache pinning per keeper profile
- seccomp profile generation from FS access trace
- `Docker_client.S` extension for `docker stats` / `docker top` (only needed if dashboard adopts container-per-keeper)

## 8. Open Questions

1. **BLAKE3 vs SHA-256** for container name derivation — Phase 1 decides; SHA-256 acceptable if opam pin friction is high.
2. **`Container_name.t` representation** — `private string` vs phantom-typed wrapper? Default: `private string` for opam-friendly cross-compilation.
3. **Mock client thread safety** — single-fiber injection vs concurrent? Default: single-fiber; concurrent injection adds complexity not yet justified by test patterns.
4. **Quarantine persistence across server restart** — in-memory only, or JSONL trail? Default: in-memory; restart loses state, restart-cleanup catches it via labels.

## 9. Rollback

Each Phase 1-5 is independently revertable. Phase 4 caller cutover lands one site per PR so a single revert clears one call path without affecting the others. Phase 5 (catch-all removal) is the only Phase whose revert is *additive* (re-adding `try ... with _ -> None`) — the RFC explicitly notes this as a one-way door once the compiler-enforced migration completes.
