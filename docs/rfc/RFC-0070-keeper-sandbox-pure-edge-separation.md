---
rfc: "0070"
title: "Keeper Sandbox Runtime — Pure/Edge Separation"
status: Draft
created: 2026-05-12
updated: 2026-05-12
author: yousleepwhen
supersedes: []
superseded_by: null
related: ["0002", "0003", "0006", "0036"]
implementation_prs: []
---

# RFC-0070: Keeper Sandbox Runtime — Pure/Edge Separation

## Changelog

- **v1 (2026-05-12, initial Draft, PR #14714)**: single `Sandbox_plan.t` covering one-shot semantics. Sandbox_executor + Docker_client.S + Mock + parser shipped through Phase 3b-iv.2.5 (#14741 / #14752 / #14764 / #14781 / #14786 / #14792 / #14797 / #14802 / #14808 / #14814 / #14821 / #14827 / #14832 / #14838 / #14844 / #14854 / #14862 / #14889).
- **v2 (2026-05-12, this amendment)**: Phase 4.1 prep audit found scope gaps in v1's §3.1 single Plan model. Audit happened in three passes:
  - First pass (iter 33) — caller survey at line 184/820/838 found 3 distinct *lifetime* patterns (session / named one-shot / anonymous one-shot). v1 Plan models only the third. v2 splits §3.1 into `Oneshot_plan` + `Session_plan`; adds `Sandbox_session_executor` (§3.2.3) + `Docker_client.S.run_detached` (§3.2.3); re-orders §4 to gate Phase 4 on Phase 3e.
  - Second pass (iter 34) — exhaustive enumeration of *all 16 docker call sites* (not just the representative line per caller) surfaced 2 additional v2 gaps:
    - `Docker_client.S.exec` v1 signature is missing `?user` and `?workdir` (proven by `keeper_turn_sandbox_runtime:278`).
    - **4th orthogonal capability**: preflight queries (`docker info --format`, `docker image inspect`) — not container lifecycle but docker-state queries. Phase 3e absorbs these as `info_security_options` + `image_inspect` on `Docker_client.S`.
  - Third pass (iter 35) — measurement-anchored verification of dependency assertions revealed two corrections:
    - **RFC-0036 cleanup_hook is on main**, not missing. v2 §4 Phase 3c.2 status changed from ⏸ blocked to ⏳ pending. PRs that landed it: #13848 (P0/P1 cleanup), #13935 (count failures), #13971 (coverage gaps). Module: `lib/keeper/keeper_lifecycle_hooks.mli`, call sites: `lib/server/server_bootstrap_loops.ml:570-571`.
    - **`Keeper_lifecycle_hooks` is a *sibling* cleanup path, not a consumer of `cleanup_outcome`**. Earlier v2 draft assumed an adapter `cleanup_outcome → unit` would be registered against the lifecycle hook; the actual `Keeper_lifecycle_hooks.event` is `Phase_transition | Tombstone_reaped` (keeper-lifecycle events), distinct from the container-level cleanup outcomes from `Sandbox_cleanup.cleanup_tick`. Both flow in parallel. §3.4 + §3.5 corrected.
  - No v1 code is invalidated — all merged work remains, only the `keeper_sandbox_plan` filename is renamed in Phase 3d. Phase 3e absorbs *all four* v2-discovered gaps in a single batch so Phase 4 cutover (4.1/4.2/4.3) can land without further `Docker_client.S` extension PRs. Phase 3c.2 is now independently schedulable.

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
- *Cleanup hook surface* — RFC-0036's hook (now on main as `Keeper_lifecycle_hooks.hook : keeper_id:string -> event -> unit`, event = `Phase_transition | Tombstone_reaped`) is **distinct** from this RFC's `cleanup_outcome`. The lifecycle hook fires on *keeper-level* events (Tombstone_reaped after registry unregister). The `cleanup_outcome` is *container-level* — produced by `Sandbox_cleanup.cleanup_tick` against the Docker fleet. The two flow in parallel: keeper-tombstoning emits the lifecycle hook, AND triggers a final `cleanup_tick`; the tick's `cleanup_outcome` is consumed by the internal `Quarantine.t` retry/alert path, not by the lifecycle hook. Phase 3c.2 does NOT need to call `Keeper_lifecycle_hooks.register` (the actual shipped API per `lib/keeper/keeper_lifecycle_hooks.mli`) to function; the existing call sites (`server_bootstrap_loops.ml:570-571`) own keeper-lifecycle cleanup, while `Sandbox_cleanup.cleanup_tick` owns container-level cleanup.
- *`Keeper_sandbox.t` public surface change* — the existing closed record + `of_meta` + `Keeper_sandbox_factory.resolve` (introduced 2026-05-11) are preserved unmodified.

## 3. Design

### 3.0 v2 caller survey (amendment driver)

Phase 4.1 prep audit (2026-05-12, iter 34 of cron `7493fe21`) enumerated **all 16 docker call sites across 3 callers** and discovered:
- **4 distinct invocation patterns** (3 run variants + 1 preflight family), not the 3 named in earlier v2 draft.
- **`Docker_client.S.exec` v1 signature is incomplete** — `keeper_turn_sandbox_runtime:278` passes `--user uid:gid` and `-w cwd` flags that v1's `~container ~cmd` cannot express.

#### 3.0.1 Run variants (3 patterns)

| Caller | Site | Pattern | Lifetime | v1 Plan fit |
|--------|------|---------|----------|-------------|
| `keeper_turn_sandbox_runtime` | line 184 | `docker run -d --rm --name <n> ... sh -lc "trap : TERM INT; while :; do sleep 3600; done"` + `docker exec <n> <cmd>` × N + `docker rm -f <n>` | **session** (turn-scoped) | ❌ not representable |
| `keeper_shell_docker` | line 820 | `docker run --rm --name <n> <image> sh -lc <cmd>` | **named one-shot** | ⚠ partial (Plan has `container_name`, but caller treats name as observable identity) |
| `keeper_sandbox_runtime` | line 838 | `docker run --rm --network none --entrypoint sh <image> -lc <script>` | **anonymous one-shot** | ✅ closest to v1 Plan |

#### 3.0.2 Cleanup/probe (shared, v1 covered)

`docker ps -a`, `docker inspect --format`, `docker rm -f` — all 9 cleanup sites across the 3 callers map cleanly onto v1's `Docker_client.S.ps_query` + `rm`. The `keeper_sandbox_runtime:699` *variadic* `inspect --format ... id1 id2 ...` (bulk inspect for performance) is a quality-of-life optimisation, not a new capability — v1 `ps_query` + per-record fetch is functionally equivalent at higher syscall cost. Deferred to Phase 4.3 follow-up if measured cost matters.

#### 3.0.3 Preflight (NEW 4th pattern — not in earlier v2 draft)

| Caller | Site | Pattern | Purpose |
|--------|------|---------|---------|
| `keeper_sandbox_runtime` | line 39 | `docker info --format '{{json .SecurityOptions}}'` | Detect seccomp/AppArmor availability at server boot |
| `keeper_sandbox_runtime` | line 807 | `docker image inspect <image>` | Verify image is locally cached before `run --rm` |

These are **read-only queries against docker state, not container lifecycle**. v1 `Docker_client.S` has no surface for them. Phase 3e introduces:

```ocaml
(* lib/keeper/docker_client.mli — added in Phase 3e *)
module type S = sig
  (* ...existing v1 surface... *)

  val info_security_options : unit -> (string list, sandbox_error) result
  (** [docker info --format '{{json .SecurityOptions}}'] parsed into the
      enabled security profiles ("name=seccomp", "name=no-new-privileges",
      etc.). Empty list when docker daemon reports no profiles. Used at
      server boot to gate [run]'s [--security-opt] choices. *)

  val image_inspect : image:string -> (image_info, sandbox_error) result
  (** [docker image inspect <image>]. Returns minimal typed info
      (digest, created_at, size_bytes); full inspect output is
      out of scope. Error variant [Image_pull_failed] (already in
      [sandbox_error]) covers "image not locally cached". *)
end
```

This is the 4th orthogonal capability, not a new lifetime model. `keeper_sandbox_runtime` calls these *before* construction of any Plan; they live in `Docker_client.S` rather than in `Sandbox_executor`/`Sandbox_session_executor`.

#### 3.0.4 `exec` flag completeness (v1 signature bug — fixed in Phase 3e)

v1 `Docker_client.S.exec : container:Container_name.t -> cmd:string -> ...`. The signature implicitly assumes the docker container's `--user` and `--workdir` defaults are correct. **`keeper_turn_sandbox_runtime:278` proves otherwise**:

```
docker exec --user <uid>:<gid> -w <container_cwd> <name> sh -lc <cmd>
```

Phase 3e extends `exec` to carry the optional `?user` and `?workdir` flags:

```ocaml
val exec
  :  ?user:int * int        (* uid, gid; defaults to image USER *)
  -> ?workdir:string        (* defaults to image WORKDIR *)
  -> container:Container_name.t
  -> cmd:string
  -> (Docker_response.exec_result, sandbox_error) result
```

Backwards-compatible: existing test callers (Phase 3b-iv.2.2 `test_docker_client_real.exec` etc.) work unchanged.

#### 3.0.5 Site count summary

| Caller | Sites | Categories |
|--------|-------|------------|
| `keeper_turn_sandbox_runtime` | 6 | run -d, inspect, rm × 2, exec, ps |
| `keeper_shell_docker` | 1 | run named |
| `keeper_sandbox_runtime` | 9 | info, inspect × 2, rm, ps × 2, image inspect, run anonymous, variadic inspect |
| **Total** | **16** | **7 distinct operations**: run (3 variants), exec, rm, inspect (container + image), ps, info |

The 7 operations are fully covered by the v2 RFC after the additions in §3.0.3 + §3.0.4. No 8th operation surfaced in this audit. `logs`, `kill`, `stop`, `wait`, `start` are not used by any of the 3 callers.

### 3.1 Pure core (Plan family)

**v2 splits the single `Keeper_sandbox_plan.t` into two sibling types**, one per lifetime model. Both share the same `Keeper_container_name.t` derivation, hash algo, and result-typed `of_request` constructor — only the runtime shape differs.

**Naming convention used in §3.1–§3.3 below**: snippets describe the *post-Phase-3d* shape. v1 ships `Keeper_sandbox_plan` (abstract `type t`) + `Keeper_container_name.t`; Phase 3d renames the file/module to `Keeper_sandbox_oneshot_plan` with no shape change. Shorthands used in prose and diagrams: `Container_name.t` stands for `Keeper_container_name.t`; `Oneshot_plan` stands for `Keeper_sandbox_oneshot_plan`; `Session_plan` stands for `Keeper_sandbox_session_plan` (introduced in §3.1.2). The shorthands carry no implementation alias — Phase 3e ships the fully-qualified module names.

#### 3.1.1 `Keeper_sandbox_oneshot_plan` (already shipped as `Keeper_sandbox_plan` — v1 type; Phase 3d is a pure rename, no shape change)

v1 ships this in `lib/keeper/keeper_sandbox_plan.{ml,mli}` with an *abstract* `type t` + accessors (not a `private` record), and `Keeper_container_name.t` (not `Container_name.t`). Phase 3d is a **pure file/caller rename** — the public surface stays identical:

```ocaml
(* Post-Phase-3d: lib/keeper/keeper_sandbox_oneshot_plan.mli
   v1 shipped form today: lib/keeper/keeper_sandbox_plan.mli *)

type plan_error = (* closed sum — see v1 .mli for current arms *)

type t  (** abstract *)

val of_request
  :  turn_id:int
  -> attempt:int
  -> meta_name:string
  -> cmd:string
  -> (t, plan_error) result

val container_name     : t -> Keeper_container_name.t
val image              : t -> string
val command            : t -> string
val timeout_budget_sec : t -> float
val equal              : t -> t -> bool
val pp                 : Format.formatter -> t -> unit
```

The conceptual fields (`container_name`, `image`, `command`, `timeout_budget_sec`) remain the same; readers should not assume an exposed record form.

Covers `keeper_sandbox_runtime` site 838 (anonymous one-shot, even though the Plan does emit a derived `--name`; docker accepts the name for `--rm` invocations).

Phase 3b-iv.2.* shipped this; v2 rename happens in Phase 3d (see §4).

#### 3.1.2 `Keeper_sandbox_session_plan` (new — Phase 4 dependency)

```ocaml
(* lib/keeper/keeper_sandbox_session_plan.mli — NEW in v2 *)
type t = private {
  container_name      : Container_name.t;
  image               : string;
  mounts              : mount list;         (* host:container:mode *)
  env_passthrough     : (string * string) list;
  network_mode        : network;            (* None | Bridge | Custom of string *)
  user                : (int * int) option; (* uid:gid *)
  ulimits             : (string * int) list;
  read_only_rootfs    : bool;
  tmpfs               : string option;
  workdir             : string option;
  startup_command     : string;             (* default: idle-sleep loop *)
  labels              : (string * string) list;
  cap_drop_all        : bool;
  no_new_privileges   : bool;
  seccomp_profile     : seccomp_choice;     (* Default | Unconfined | File of path *)
  pids_limit          : int;
  memory_limit        : string;             (* "2g", etc. *)
}

val of_request
  : turn_id:int
    -> attempt:int
    -> meta:Keeper_types.keeper_meta
    -> host_root:string
    -> uid:int
    -> gid:int
    -> network_mode:network
    -> (t, plan_error) result
```

Covers `keeper_turn_sandbox_runtime:184` (persistent session). The startup_command default is the existing trap-and-sleep idiom. The `Plan` represents *one container's lifetime*, NOT a single command — commands are issued via `Session.exec` (§3.2.2) against an already-started container.

#### 3.1.3 Named one-shot — represented via Oneshot_plan extension

`keeper_shell_docker:820` (named one-shot) is *not* a third sibling type. It is `Oneshot_plan` with caller-observable `container_name`. The existing `container_name` field is already exposed by `Oneshot_plan.container_name`; the only delta is that `keeper_shell_docker` will *consume* the field for probe/cleanup, where `keeper_sandbox_runtime` ignores it. No type extension required.

#### 3.1.4 `Container_name.t` derivation (unchanged)

`Container_name.t` is a private string derived as `"masc-keeper-" ^ hex(Keeper_hash_algo.digest_bytes hash_algo (turn_id ‖ attempt ‖ suffix))[0..31]`, where `Keeper_hash_algo.t = SHA_256 | SHA_512` (closed variant, default `SHA_256` per §8 Q1). The hex slice takes the first **32 hex chars = 16 bytes (128 bits)** of the digest. Direct collision probability is 1/2^128; birthday-bound collision threshold (concurrent keepers in the same fleet) is ~2^64 ≈ 1.8×10^19. Both Oneshot and Session Plan share this derivation. `Container_name.of_external_string` (#14871) remains the unsafe-wrap escape hatch for `docker ps` output ingestion.

(BLAKE3 was originally in the variant; deferred to a follow-up — opam `digestif` 1.3.0 ships BLAKE2B/2S but not BLAKE3. Hex encoding chosen over base36 to match the existing `Digestif.to_hex` convention used 8+ times elsewhere in `lib/`.)

### 3.2 Edge layer (Docker_client + executors)

#### 3.2.1 `Docker_client.S` (v1 surface — kept as base capability layer; post-Phase-3d naming)

```ocaml
(* lib/keeper/docker_client.mli — v1 surface, post-Phase-3d names
   (v1 shipped today: takes Keeper_sandbox_plan.t / Keeper_container_name.t) *)
module type S = sig
  val run         : Keeper_sandbox_oneshot_plan.t -> (Docker_response.exec_result, sandbox_error) result
  val exec        : container:Container_name.t -> cmd:string -> (Docker_response.exec_result, sandbox_error) result
  val ps_query    : labels:(string * string) list -> (Docker_response.ps_record list, sandbox_error) result
  val rm          : Container_name.t -> (unit, sandbox_error) result
end
```

`run` is *one-shot only*. Session lifecycle is built on top via `start` + multiple `exec` + `rm` rather than extending `S` with a `start_session` primitive (kept compositional — `Sandbox_session_executor` orchestrates).

#### 3.2.2 `Sandbox_executor` (v1 — for `Oneshot_plan`)

```ocaml
module Make (D : Docker_client.S) : sig
  val execute_plan
    :  Keeper_sandbox_oneshot_plan.t
    -> (Docker_response.exec_result, sandbox_error) result
  val execute_plan_with_retry
    :  retry:Keeper_backoff_policy.t
    -> Keeper_sandbox_oneshot_plan.t
    -> (Docker_response.exec_result, sandbox_error) result
end
```

Shipped Phase 3c.0/3c.1. Consumer: `keeper_sandbox_runtime:838` (anonymous one-shot, Phase 4.3 below).

#### 3.2.3 `Sandbox_session_executor` (NEW in v2 — for `Session_plan`)

```ocaml
(* lib/keeper/sandbox_session_executor.mli — NEW *)
module Make (D : Docker_client.S) : sig
  type t  (* private — opaque session handle wrapping Container_name.t + state *)

  val start
    :  Keeper_sandbox_session_plan.t
    -> (t, sandbox_error) result
  (** Spawns [docker run -d --rm --name <derived> ... <startup_command>]
      by delegating to [D.run_detached] (added in Phase 3e — see prose
      below). Returns [t] holding the [Container_name.t] for subsequent
      [exec]/[rm]. *)

  val exec
    :  t
    -> cmd:string
    -> (Docker_response.exec_result, sandbox_error) result
  (** Delegates to [D.exec] against the held container_name. *)

  val cleanup
    :  t
    -> (unit, sandbox_error) result
  (** Delegates to [D.rm]. Idempotent. *)

  val container_name : t -> Container_name.t
  (** Observable for probe/inspect from the caller's POV. *)
end
```

Determinism contract: same `Keeper_sandbox_session_plan.t` ⇒ identical inner one-shot plan ⇒ identical `Container_name.t`. The session handle `t` carries non-determinism (start time, state) but is opaque to callers.

`-d` (detach) is the only `S.run` invocation that produces a session-shaped output (PID instead of exec_result). v2 §3.2.3 keeps `D.run` returning `exec_result` and treats the `-d` *flag* as a session-runtime concern: `Sandbox_session_executor.start` composes the `-d` argv internally by *not* using `D.run` directly. The cleanest factoring is: extend `Docker_client.S` with `run_detached : Keeper_sandbox_session_plan.t -> (Container_name.t, sandbox_error) result` (separate from `run`). Phase 3e (v2 amend) implements both `Mock` and `Real` variants of `run_detached`.

#### 3.2.4 Composition diagram

```text
Keeper_sandbox_oneshot_plan ─→ Sandbox_executor.Make(D).execute_plan ─→ D.run
                                                                       ↑
                                                               same D underneath
                                                                       ↓
Keeper_sandbox_session_plan ─→ Sandbox_session_executor.Make(D).start ─→ D.run_detached
                                                                       ↑
                                                                       ↓
                                                               D.exec (N times)
                                                                       ↓
                                                               D.rm
```

Both `Sandbox_executor` and `Sandbox_session_executor` are functors on the same `Docker_client.S` capability layer. `D.run` and `D.run_detached` are sibling primitives.

### 3.3 Typed docker probe

**Shipped surface today** (`lib/keeper/docker_response.mli`, post Phase 3b-iv.2):

```ocaml
type ps_status =
  | Created | Running | Paused | Restarting | Exited | Dead
[@@deriving show, eq]

type ps_record = {
  id     : string;
  name   : Keeper_container_name.t;
  status : ps_status;
  labels : (string * string) list;
}
[@@deriving show, eq]
```

**Intent (follow-up beyond v2 scope, not in this RFC)** — listed here so the cleanup/quarantine path's data needs are explicit, NOT promised by this RFC:

- Carry exit code on `Exited` (today `parse_state` consumes only the `State` token and discards the exit code; the exit code is available from `docker inspect` separately).
- Add `created_at : Mtime.t` to `ps_record` (today the cleanup tick reads `first_seen` from `Quarantine.t`, not from the ps row).
- Strengthen `id : string` to a typed `Container_id.t`.

These are explicitly **out of scope for v2**; v2 ships against the shipped surface above. The intent block is preserved as a forward marker for the post-Phase-4 cleanup hardening RFC. Underlying call: `docker ps --format '{{json .}}' --filter label=...`. JSON line-delimited, parsed via `ppx_deriving_yojson`. `Probe_format_drift` error fired if a record fails to parse — caller sees a typed alert, not a silent miss.

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

`Quarantine.t` is a per-server-session Set of `(Container_name.t, attempts:int, first_seen:Mtime.t)`. Retry/alert thresholds are NOT magic numbers — they live in a typed `Backoff_policy.t = { max_attempts : int; backoff : Time.span -> int -> Time.span; alert_after : int }` resolved at edge from `config/sandbox.toml`. Default values (`max_attempts=3`, exponential `backoff` from 1s to 60s, `alert_after=3`) are *defaults*, not literals scattered through the implementation. On `attempts ≥ alert_after`, `alert_dispatched` becomes true and an operator alert fires (separate from the existing Prometheus counter, which becomes a *by-product*, not the decision mechanism).

**Relationship to `Keeper_lifecycle_hooks` (RFC-0036 surface on main)** *(measurement-anchored, iter 35)*: This RFC's `cleanup_outcome` is *not* a hook payload. The lifecycle hook receives `event = Tombstone_reaped` after a keeper unregister; the container cleanup tick is a separate critical-path that produces `cleanup_outcome` for internal `Quarantine.t` consumption. No `cleanup_outcome → unit` adapter against `Keeper_lifecycle_hooks` is needed — they are sibling cleanup paths, not layered. (Earlier v2 draft assumed they were layered; iter 35 audit corrected this.)

`Phase_transition` event in `Keeper_lifecycle_hooks.event` is *not yet emitted* (Phase A.2 follow-up). Phase 3c.2 must NOT depend on it.

### 3.5 Containment with existing modules

| Existing | Role in this RFC |
|----------|------------------|
| `Keeper_sandbox.t` (closed record, `of_meta`) | Input to `Sandbox_plan.of_request` — preserved unchanged |
| `Keeper_sandbox_factory.resolve` (memoized per `(in_playground, network_mode)`) | Calls into `Sandbox_executor` in Phase 4 — wiring change only |
| `Keeper_sandbox_containment.check_{read,write}_target` (RFC-0006 Phase B-1) | Continues as host-side defense-in-depth — unchanged |
| `Keeper_lifecycle_hooks` (RFC-0036, on main) | Sibling cleanup path — keeper-level Tombstone_reaped event; NOT the consumer of `cleanup_outcome` (corrected iter 35). Container-level cleanup runs in `Sandbox_cleanup.cleanup_tick` independently. |

## 4. Migration

v2 re-orders Phase 3-5 to gate Phase 4 cutover on Session API delivery. Phases 0-3 shipped before v2 and retain their v1 numbering.

| Phase | Deliverable | RFC dependency | Risk | Status |
|-------|-------------|----------------|------|--------|
| **0** | `pr-rfc-check.sh` sandbox patterns + bash 3.2 compat | none | done | ✅ `~/me`@`d0add960d7` |
| **1** | `keeper_sandbox_plan.mli` + `docker_client.mli` (signatures, empty stubs) | none | LOW | ✅ Phase 3a #14741 |
| **2** | Plan + Real Docker_client implementations, existing callers unchanged | Phase 1 | LOW | ✅ Phase 3b-iv.2.0–2.4 #14838/14844/14854/14862/14871 |
| **3** | `Sandbox_executor` (oneshot) + `Docker_client.Mock` + parser unit tests | Phase 2 | MEDIUM | ✅ Phase 3c.0/3c.1 #14821/14827, Phase 3b-iv.2.5 #14889 |
| **3d** *(v2)* | Rename `keeper_sandbox_plan` → `keeper_sandbox_oneshot_plan` (file + caller renames; no behavior change). Necessary to free the unqualified name for the Session/Oneshot split. | Phase 3 | LOW — pure rename refactor | ⏳ pending |
| **3e** *(v2)* | `Docker_client.S` extensions: (a) `run_detached`, (b) `exec` adds `?user` + `?workdir`, (c) `info_security_options`, (d) `image_inspect`. Plus `Keeper_sandbox_session_plan` + `Sandbox_session_executor.Make` + unit tests. Mock + Real both updated. | Phase 3d | MEDIUM — new edge primitives + signature extension | ⏳ pending |
| **3c.2** | Cleanup quarantine state machine (`Quarantine.t` + alert path; no `Keeper_lifecycle_hooks` adapter — sibling path per §2 / §3.4) | Phase 3 | MEDIUM | ⏳ pending — Phase 3 is the sole prerequisite (no cross-RFC dependency) |
| **4.1** *(v2)* | Caller cutover `keeper_turn_sandbox_runtime` → `Sandbox_session_executor` (one PR) | Phase 3e | MEDIUM | ⏳ pending |
| **4.2** *(v2)* | Caller cutover `keeper_shell_docker:820` → `Sandbox_executor` w/ named one-shot semantics (one PR) | Phase 3 | MEDIUM | ⏳ pending |
| **4.3** *(v2)* | Caller cutover `keeper_sandbox_runtime:838` → `Sandbox_executor` w/ anonymous one-shot semantics (one PR) | Phase 3 | MEDIUM | ⏳ pending |
| **5** | Catch-all removal: delete the 8 `try ... with _ -> None` sites in `keeper_sandbox_control.ml`; compiler enforces caller migration | Phase 4.1+4.2+4.3 all merged | LOW — compiler is the migration check | ⏳ pending |

**v2 ordering rationale**:
- Phase 4.2 + 4.3 (one-shot caller cutovers) do NOT depend on Phase 3e — they can land in parallel with Session API work. Originally v1 implied a serial order; v2 makes the parallelism explicit.
- Phase 4.1 (session caller) is the only branch that *requires* Phase 3e.
- Phase 5 still gates on all 3 cutovers (compiler exhaustiveness across the subsystem).
- Phase 3c.2 (cleanup quarantine) is independent of Phase 4 — it owns container-level cleanup orthogonal to `Keeper_lifecycle_hooks` keeper-level cleanup. As of iter 35 (2026-05-12) the RFC-0036 cleanup_hook is on main and the dependency is satisfied; Phase 3c.2 is now schedulable independently of Phase 4.

Phases are independently mergeable and revertible. Phase 5 closes the loop by making the old anti-pattern syntactically unwritable in this subsystem.

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
| RFC-0036 lifecycle hook (`Keeper_lifecycle_hooks`) coexists with this RFC's `Sandbox_cleanup.cleanup_tick` | Per §2 / §3.4: the two are **sibling** paths (not layered). The lifecycle hook fires on `Tombstone_reaped`; `cleanup_tick` produces `cleanup_outcome` consumed by the internal `Quarantine.t`. No `Sandbox_cleanup.adapter` is introduced. The Result.t escalation stays internal to the sandbox subsystem. |
| BLAKE3 dependency in OCaml — current opam constraints | RESOLVED Phase 3b-i (#14741 follow-up): `digestif` 1.3.0 (already present, used 8+ times in `lib/`) ships BLAKE2B/2S/SHA-256/SHA-512 but **not BLAKE3**. Adopted `Keeper_hash_algo.t = SHA_256 \| SHA_512` for Phase 3b. Future BLAKE3 = separate PR adding `blake3` opam dep + variant arm. |

## 7. Out of Scope

- Docker socket multiplexing for fleet (multi-host scaling)
- BuildKit cache pinning per keeper profile
- seccomp profile generation from FS access trace
- `Docker_client.S` extension for `docker stats` / `docker top` (only needed if dashboard adopts container-per-keeper)
- **Generalised container orchestration** — RFC-0070 v2 covers only the three docker invocation patterns surveyed in §3.0. Hypothetical fourth patterns (e.g. `docker compose` multi-container, `docker swarm` service replication) are out of scope; a new RFC would be required.
- **Streaming exec** — `Sandbox_session_executor.exec` returns the full `Exec_result.t` (stdout/stderr captured). Streaming output back to the caller during long-running commands is not in scope; callers needing streaming continue to bypass this layer.

## 8. Open Questions

1. **Default Keeper_hash_algo.t** — RESOLVED Phase 3b-i: variant is `SHA_256 | SHA_512`, default `SHA_256`. BLAKE3 deferred (digestif 1.3.0 lacks it). Future expansion = variant arm + opam dep in a separate PR.
2. **`Container_name.t` representation** — RESOLVED Phase 3b-ii (#14764): `private string` with `to_string` accessor and `of_external_string` unsafe-wrap escape hatch (#14871) for docker ps output ingestion.
3. **Mock client thread safety** — RESOLVED Phase 3b-iv.1b (#14808 → Queue.t perf fix #14814): single-fiber strict-FIFO injection.
4. **Quarantine persistence across server restart** — in-memory only, or JSONL trail? Default: in-memory; restart loses state, restart-cleanup catches it via labels. (Phase 3c.2 implements the `Quarantine.t` state machine; the `Keeper_lifecycle_hooks` dependency cited in earlier drafts is removed — see §2 / §3.4.)
5. **Session container `--rm` flag** *(v2)* — `Session_plan` startup will use `docker run -d --rm --name <n>` to match current `keeper_turn_sandbox_runtime` behavior. `--rm` means the container is *auto-removed on stop* — explicit `Session.cleanup` (calling `D.rm`) handles the *normal* shutdown path; `--rm` is a backstop for crash/kill exits. Open: should `Session.cleanup` log a warning if the container is already gone (auto-removed by docker)? Default: silent success (idempotent), since `D.rm` returns Ok on a vanished container would be ambiguous vs Cleanup_failed.
6. **Session.exec timeout policy** *(v2)* — Each `exec` call carries its own timeout (per-command), while the Session_plan has no aggregate session lifetime budget. Open: should there be a session-wide deadline that fires when sum-of-exec-timeouts exceeds it, or is per-call sufficient? Default: per-call; turn-level orchestrator (the caller) is responsible for aggregate budget. The session itself is an indefinite resource lease.
7. **`run_detached` vs `start_session`** *(v2)* — §3.2.3 declares `Docker_client.S.run_detached : Keeper_sandbox_session_plan.t -> (Container_name.t, sandbox_error) result` as a new edge primitive. Alternative considered: a higher-level `Sandbox_session_executor.start` that calls `D.run` with a synthesised plan whose result is discarded and whose name is extracted post-hoc from `D.ps_query`. Decision: `run_detached` is cleaner — `-d` flag is not representable in `D.run`'s `Oneshot_plan` input (which carries `image + command`, not lifecycle), so introducing it would distort the one-shot type. Cost: two `Docker_client.S` primitives instead of one. Benefit: each carries a typed lifetime contract.

## 9. Rollback

Each Phase 1-5 is independently revertible. Phase 4 caller cutover lands one site per PR so a single revert clears one call path without affecting the others. Phase 5 (catch-all removal) is the only Phase whose revert is *additive* (re-adding `try ... with _ -> None`) — the RFC explicitly notes this as a one-way door once the compiler-enforced migration completes.
