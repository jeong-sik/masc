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
implementation_prs: ["14714", "14741", "14821", "14827", "14889", "14899", "14934", "14940", "14947", "14951", "14956"]
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
- **v2.1 (2026-05-12, doc sync)**: Phase 3d shipped (#14934 — pure rename, 14 files, +51/-51); §4 status flipped to ✅; §3.1.1 / naming-convention / §3.5 / §5 Phase 2 references updated from `Keeper_sandbox_plan` to the shipped `Keeper_sandbox_oneshot_plan`. §1 F6 corrected: iter-1-2 counted 8 `try ... with _ -> None` sites in `keeper_sandbox_control.ml`; the `Masc_exec.Exec_gate` migration (#14329/#14359) since resolved ~7, leaving 1 `Cancelled`-guarded residual at `git_string_opt:306-308` — §4 Phase 5 re-scoped accordingly; §5 Phase 5 validation note clarified (single-line `rg` misses the multi-line catch-all). §3.5 `Keeper_sandbox.t`/`of_request` relationship corrected (`of_request` takes `~meta_name:string`, not `Keeper_sandbox.t`). Sources: PR #14899 review comments (iter 39/40 audits), PR #14934.
- **v2.2 (2026-05-12, Phase 3e sync + §3.1.2 design resolution)**: Phase 3e fragmented — the three self-contained edge primitives shipped one PR each rather than the single batch v2 envisaged (safe: none exposes a new layer): (b) `Docker_client.S.exec` gains `?user`/`?workdir` + pure `Docker_client_real.exec_argv` (#14947); (c) `info_security_options` + pure `parse_security_options` (#14951); (d) `image_present` — **narrowed** from the earlier `image_inspect → image_info` sketch (§3.0.3 corrected: nothing consumes inspect data, so it's a presence check `(unit, _) result`; no new `Image_not_found` variant) (#14956). §3.2.1 surface block updated to the current shape; §4 Phase 3e split into 3e-b/c/d (✅) + 3e-aef (⏳ — `run_detached` (a) + `Keeper_sandbox_session_plan` (e) + `Sandbox_session_executor.Make` (f), one PR). §3.1.2's 4 paper-design questions (iter 37 audit) resolved: `labels` is a derived field (`of_request` composes it from `~meta_name`/`~base_path`/`~container_kind`/`~network_mode`/`~turn_id`); `mounts` is unified (`of_request` composes workspace + identity mounts from `~host_root`/`~uid`/`~gid`); `env_passthrough` renamed `env_overrides` (4 hardcoded defaults + `?extra_env`, not a host-env passthrough); `ulimits : ulimit list` with `type ulimit = {name;soft;hard}` (default `nofile=N:N` unchanged). `of_request` takes `~meta_name:string` not `~meta:keeper_meta` (cross-module-dep-free, matching `Oneshot_plan`). §3.2.3 `Sandbox_session_executor.exec` now threads the plan's `user`/`workdir` through `D.exec`. Sources: PRs #14947/#14951/#14956, PR #14899 iter 37 comment.
- **v2.3 (2026-05-12, §3.1.2 pure/edge boundary correction)**: iter 47 measured the helper *bodies* `start_container` calls (not just its argv shape) and found the v2.2 §3.1.2 resolution was incomplete on two points. (1) `docker_label_args` is **not purely derivable** — it emits an `owner_pid = Unix.getpid()` label and a `started_at = "%.3f" (Unix.gettimeofday())` label. So `Keeper_sandbox_session_plan.of_request` (pure) composes only the **7 deterministic** labels (component / `base_path_hash` / keeper / kind / network / turn_id / ttl_sec); the edge (`run_detached` / `Sandbox_session_executor.start`) appends the PID + started_at labels at spawn (order-irrelevant to docker). (2) `docker_user_identity_mount_args` performs **file I/O** — `mkdir_p <host_root>/.docker-identity` + `save_file_atomic` of `passwd`/`group` — before returning the mount args. So the Plan carries both `mounts` (the deterministic `-v …:/etc/passwd:ro` etc. args) *and* `identity_files : (string * string) list` (the `(path, content)` pairs the edge must write); the *content* is deterministic given `uid`/`gid`, only *writing* is I/O. Also: seccomp *resolution* (`ensure_keeper_sandbox_runtime`, a daemon probe) and the `docker_command_argv ()` prefix are edge. `of_request` reads `Env_config_keeper.KeeperSandbox.*` for `pids_limit`/`memory_limit`/`ulimits` — config reads are stable per run, not the wall-clock/PID/random/daemon-I/O non-determinism the split targets. §3.1.2 rewritten with a pure/edge table; §3.2.3 `run_detached` prose updated to spell out the edge work. Source: iter 47 measurement of `keeper_sandbox_runtime.ml:179-271` + `keeper_turn_sandbox_runtime.ml:152-220`.
- **v2.4 (2026-05-12, Phase 3e-aef fragmentation + 3e-f shipped)**: the planned single 3e-aef PR was split into three (safe — no part exposes a new layer; same precedent as the 3e-b/c/d split): (e) `Keeper_sandbox_session_plan` (pure session plan — `of_request`, the 7 deterministic labels, `identity_files`, `env_overrides`, `ulimits`) ✅ #14970; (a) `Docker_client.S.run_detached : Keeper_sandbox_session_plan.t -> (Keeper_container_name.t, sandbox_error) result` + `Mock` (default `Ok plan.container_name`, no fail-closed — there is nothing to "expect" on the mock happy path) + pure `Docker_client_real.run_detached_argv` ✅ #14973; (f) `Sandbox_session_executor.Make(D : Docker_client.S)` — the thin orchestrator: `start` → `D.run_detached` → wrap in an opaque session handle (`Container_name.t` + the originating plan, so `exec` can thread `user`/`workdir`); `exec` → `D.exec ?user ?workdir ~container ~cmd ()`; `cleanup` → `D.rm`; `container_name : t -> Keeper_container_name.t`. No I/O / clock / Random in the functor — all behind `D`. §4 row 3e-aef replaced by 3e-e/3e-a/3e-f; Phase 4.1's dependency updated accordingly. Sources: PRs #14970/#14973 + this PR.

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
| F6 | `try ... with _ -> None` in git/probe paths — any failure becomes "not found", reason lost. Iter 1-2 counted 8 sites in `keeper_sandbox_control.ml`; the `Masc_exec.Exec_gate` migration (#14329 / #14359) since resolved ~7 of them. **1 residual** catch-all remains at `git_string_opt` (`keeper_sandbox_control.ml:306-308`), `Cancelled`-guarded (re-raises `Eio.Cancel.Cancelled` before swallowing). The two `Sys_error _ -> false` catches at `:261-266` are *typed*, not catch-all. | `keeper_sandbox_control.ml:306-308` | LOW (mostly resolved) |
| F7 | Cleanup loop increments `metric_keeper_turn_cleanup_failures` counter and returns empty — no retry, no escalation | `keeper_turn_sandbox_runtime.ml:466-468`, `keeper_sandbox_runtime.ml:618-625` | HIGH (CLAUDE.md §워크어라운드 §1 — counter-as-fix) |

F1, F3, F6 are direct instances of CLAUDE.md §AI 코드 생성 안티패턴: hardcoded scattered (#1), unknown→permissive default (#2), `_ -> None` catch-all (#4). F7 trips the §워크어라운드 거부 §1 — telemetry-as-fix. (F6 has since been largely closed by the exec_gate migration — see the F6 row; Phase 5 below now scopes to the 1 residual site rather than 8.)

## 2. Goals / Non-Goals

**Goals**
- **G1** *Deterministic ID*: `container_name = pure_fn(turn_id, attempt, suffix)`. Same input → same output. Wall-clock removed from the construction path.
- **G2** *Typed daemon errors*: every docker daemon call returns `(_, sandbox_error) result` where `sandbox_error` is a closed sum (`Daemon_unreachable | Image_pull_failed | Container_oom | Exec_timeout | Probe_format_drift | Cleanup_failed`; Phase 3e adds `| Image_not_found` for the `docker image inspect` "no such image" case — distinct from `Image_pull_failed`, which is for a pull that was *attempted* and failed). No catch-all.
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
(* lib/keeper/docker_client.mli — Phase 3e additions
   (c) info_security_options — SHIPPED #14951
   (d) image_present         — SHIPPED #14956 *)
module type S = sig
  (* ...existing v1 surface... *)

  val info_security_options : unit -> (string list, sandbox_error) result
  (** [docker info --format '{{json .SecurityOptions}}'] parsed into the
      lowercased security-profile list ("name=seccomp",
      "name=no-new-privileges", etc.). [Ok []] when the daemon reports
      none ([null] / [] payload). Daemon-level failure ⇒
      [Daemon_unreachable]; a payload that is neither a JSON array nor
      [null] (a docker output-format change) ⇒ [Probe_format_drift] —
      not a silent [Ok []]. Used at server boot to gate [run]'s
      [--security-opt] choices. *)

  val image_present : image:string -> (unit, sandbox_error) result
  (** [docker image inspect <image>] — [Ok ()] when the image exists
      locally. A non-zero exit conflates "not found locally" (exit 1 —
      common; the caller may then pull) with "daemon down" (also exit
      1) ⇒ [Image_pull_failed] (the single "image unavailable for this
      run" signal). A synthesized [WEXITED 127] (docker CLI missing) is
      the one disambiguated case ⇒ [Daemon_unreachable].

      Scope narrowing vs the earlier v2 sketch: this is a *presence
      check* ([(unit, _) result]), not the [image_inspect → image_info]
      proposed before — nothing consumes inspect data (the keeper only
      checks presence), so an [image_info] type would be over-specced.
      No new [Image_not_found] variant either; a future RFC may split
      [Image_pull_failed] into [Image_not_found | Daemon_unreachable]
      if a preflight ever needs to distinguish. *)
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

**Naming convention used in §3.1–§3.3 below**: snippets describe the *current* shape. The v1 type was `Keeper_sandbox_plan` (abstract `type t`) + `Keeper_container_name.t`; Phase 3d (#14934, merged 2026-05-12) renamed the file/module to `Keeper_sandbox_oneshot_plan` with no shape change. Shorthands used in prose and diagrams: `Container_name.t` stands for `Keeper_container_name.t`; `Oneshot_plan` stands for `Keeper_sandbox_oneshot_plan`; `Session_plan` stands for `Keeper_sandbox_session_plan` (introduced in §3.1.2, ships in Phase 3e). The shorthands carry no implementation alias — the fully-qualified module names are authoritative.

#### 3.1.1 `Keeper_sandbox_oneshot_plan` (shipped — renamed from `Keeper_sandbox_plan` in Phase 3d #14934, no shape change)

Shipped in `lib/keeper/keeper_sandbox_oneshot_plan.{ml,mli}` (renamed from `keeper_sandbox_plan.{ml,mli}` in Phase 3d #14934) with an *abstract* `type t` + accessors (not a `private` record), and `Keeper_container_name.t` (not `Container_name.t`). Phase 3d was a **pure file/caller rename** — the public surface is identical to the v1 type:

```ocaml
(* lib/keeper/keeper_sandbox_oneshot_plan.mli — shipped (#14934) *)

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

Phase 3b-iv.2.* shipped this; Phase 3d (#14934) renamed the module — no shape change.

#### 3.1.2 `Keeper_sandbox_session_plan` (new — Phase 3e (e); Phase 4.1 dependency)

The fields below were measured byte-for-byte against `keeper_turn_sandbox_runtime.start_container`'s argv (iter 37 audit), and the *helper bodies* it calls (`docker_label_args`, `docker_user_identity_mount_args`, `docker_user_env_args`, `docker_nofile_args`) were measured in iter 47 — that pass found two things the iter-37/v2.2 resolution missed: **`docker_label_args` is not purely derivable** (it includes `owner_pid = Unix.getpid()` and `started_at = Unix.gettimeofday()` labels), and **`docker_user_identity_mount_args` performs file I/O** (`mkdir_p` + `save_file_atomic` of `passwd`/`group`) before returning the mount args. v2.3 corrects the pure/edge boundary accordingly.

**Pure/edge split for `Keeper_sandbox_session_plan`:**

| Concern | Lives in | Why |
|---------|----------|-----|
| `container_name` (hash of turn_id‖attempt‖suffix), `image`, `startup_command`, `cap_drop_all`, `no_new_privileges`, `seccomp_profile` (the *choice*), `read_only_rootfs`, `tmpfs`, `workdir`, `user`, `network_mode`, `pids_limit`, `memory_limit`, `env_overrides` (4 hardcoded `HOME`/`USER`/`LOGNAME`/`SHELL` + `?extra_env`), `ulimits` | **Plan** (`of_request`, pure) | deterministic given the request inputs. (`pids_limit`/`memory_limit`/`ulimits` are read from `Env_config_keeper.KeeperSandbox.*` — config reads are stable per run, not the wall-clock/PID/random/daemon-I/O non-determinism the split targets.) |
| `mounts` — the workspace volume (`-v host_root:container_root:rw`) **and** the identity mounts (`-v <host_root>/.docker-identity/passwd:/etc/passwd:ro`, `…/group:/etc/group:ro`) | **Plan** | the mount *args* are deterministic (path concat). Note: the identity mounts only *work* if the files exist — see `identity_files` below. |
| `identity_files : (string * string) list` — the `(path, content)` pairs the edge must write before the mounts are valid: `(<host_root>/.docker-identity/passwd, "root:x:0:0:…\nkeeper:x:<uid>:<gid>:…\n")` and `(…/group, "root:x:0:\nkeeper:x:<gid>:\n")` | **Plan** | the *content* is deterministic given `uid`/`gid`; only *writing* it is I/O. The Plan describes what must exist; the edge materialises it. |
| `labels` — the 7 **deterministic** labels: component (static), `base_path_hash` (MD5 of normalised `base_path`), keeper (`sanitize_label_value meta_name`), kind (`sanitize_label_value container_kind`), network (`sanitize_label_value network_label`, where `network_label` is derived from `network_mode`), turn_id, ttl_sec | **Plan** | pure string ops. |
| `owner_pid` label (`Unix.getpid()`), `started_at` label (`Printf.sprintf "%.3f" (Unix.gettimeofday())`) | **edge** (`run_detached` / `Sandbox_session_executor.start`) | PID and wall-clock are spawn-time facts, not plan facts. Appended to the Plan's `labels` at spawn; docker treats `--label` order-independently so position is irrelevant. |
| seccomp *resolution* (`ensure_keeper_sandbox_runtime` → `--security-opt seccomp=<path>`), the `docker_command_argv ()` prefix (binary path + global flags), the actual `docker run -d` spawn | **edge** | `ensure_keeper_sandbox_runtime` is a daemon probe; the prefix and spawn are the invocation envelope. |

The 4 iter-37 design questions, re-resolved under this split: `labels` is **derived** but only its *deterministic* part lives in `of_request` (the edge adds PID/started_at); `mounts` is **unified** (workspace + identity, both as `mount`s) *plus* `identity_files` carries the file specs the edge writes; `env_passthrough` → **`env_overrides`** (4 hardcoded + `?extra_env`, no host-env inheritance); `ulimits : ulimit list` with `type ulimit = { name; soft; hard }` (default `nofile=N:N` unchanged).

```ocaml
(* lib/keeper/keeper_sandbox_session_plan.mli — Phase 3e (e) *)
type ulimit = { name : string; soft : int; hard : int }

type t  (** abstract — like Oneshot_plan; accessors below, no exposed record *)

(* Accessors:
     container_name   : t -> Container_name.t
     image            : t -> string
     mounts           : t -> mount list                  (* workspace + identity mount ARGS *)
     identity_files   : t -> (string * string) list      (* (path, content) for the edge to write *)
     env_overrides    : t -> (string * string) list      (* 4 hardcoded defaults + ?extra_env *)
     network_mode     : t -> network                     (* Network_none | Network_inherit | … *)
     user             : t -> (int * int) option          (* uid:gid → --user *)
     ulimits          : t -> ulimit list
     read_only_rootfs : t -> bool
     tmpfs            : t -> string option
     workdir          : t -> string option
     startup_command  : t -> string                      (* default: trap-and-sleep idle loop *)
     labels           : t -> (string * string) list      (* 7 deterministic labels; edge adds PID + started_at *)
     cap_drop_all     : t -> bool
     no_new_privileges : t -> bool
     seccomp_profile  : t -> seccomp_choice               (* Default | Unconfined | File of path — the choice, not the resolved path *)
     pids_limit       : t -> int
     memory_limit     : t -> string                       (* "2g", etc. *) *)

val of_request
  :  turn_id:int
  -> attempt:int
  -> meta_name:string            (* keeper key for label derivation; NOT keeper_meta — stays cross-module-dep-free, like Oneshot_plan *)
  -> base_path:string            (* for the base_path_hash label *)
  -> container_kind:string       (* "turn" | "shell" | … — for the container_kind label *)
  -> network_mode:network        (* drives network args AND the network label *)
  -> host_root:string            (* workspace mount source AND .docker-identity dir root *)
  -> uid:int
  -> gid:int
  -> ?ttl_sec:float              (* if > 0, emits a ttl label; default None *)
  -> ?extra_env:(string * string) list   (* opt-in caller env additions; default [] *)
  -> unit                        (* trailing unit so OCaml can erase ?ttl_sec / ?extra_env *)
  -> (t, plan_error) result
```

Covers `keeper_turn_sandbox_runtime:184` (persistent session). The startup_command default is the existing trap-and-sleep idiom. The `Plan` represents *one container's lifetime*, NOT a single command — commands are issued via `Session.exec` (§3.2.3) against an already-started container.

#### 3.1.3 Named one-shot — represented via Oneshot_plan extension

`keeper_shell_docker:820` (named one-shot) is *not* a third sibling type. It is `Oneshot_plan` with caller-observable `container_name`. The existing `container_name` field is already exposed by `Oneshot_plan.container_name`; the only delta is that `keeper_shell_docker` will *consume* the field for probe/cleanup, where `keeper_sandbox_runtime` ignores it. No type extension required.

#### 3.1.4 `Container_name.t` derivation (unchanged)

`Container_name.t` is a private string derived as `"masc-keeper-" ^ hex(Keeper_hash_algo.digest_bytes hash_algo (turn_id ‖ attempt ‖ suffix))[0..31]`, where `Keeper_hash_algo.t = SHA_256 | SHA_512` (closed variant, default `SHA_256` per §8 Q1). The hex slice takes the first **32 hex chars = 16 bytes (128 bits)** of the digest. Direct collision probability is 1/2^128; birthday-bound collision threshold (concurrent keepers in the same fleet) is ~2^64 ≈ 1.8×10^19. Both Oneshot and Session Plan share this derivation. `Container_name.of_external_string` (#14871) remains the unsafe-wrap escape hatch for `docker ps` output ingestion.

(BLAKE3 was originally in the variant; deferred to a follow-up — opam `digestif` 1.3.0 ships BLAKE2B/2S but not BLAKE3. Hex encoding chosen over base36 to match the existing `Digestif.to_hex` convention used 8+ times elsewhere in `lib/`.)

### 3.2 Edge layer (Docker_client + executors)

#### 3.2.1 `Docker_client.S` (capability layer — current shape after Phase 3e b/c/d)

```ocaml
(* lib/keeper/docker_client.mli — current (Phase 3d names + Phase 3e b/c/d) *)
module type S = sig
  val run  : Keeper_sandbox_oneshot_plan.t -> (Docker_response.exec_result, sandbox_error) result

  (* (b) #14947 — ?user (uid,gid)→--user, ?workdir→-w; trailing unit so
     OCaml can erase the leading optionals (all params labeled). *)
  val exec
    :  ?user:int * int -> ?workdir:string
    -> container:Container_name.t -> cmd:string -> unit
    -> (Docker_response.exec_result, sandbox_error) result

  val ps_query : labels:(string * string) list -> (Docker_response.ps_record list, sandbox_error) result
  val rm       : Container_name.t -> (unit, sandbox_error) result

  (* (c) #14951 *)
  val info_security_options : unit -> (string list, sandbox_error) result
  (* (d) #14956 — presence check; see §3.0.3 for the image_inspect→image_present narrowing *)
  val image_present : image:string -> (unit, sandbox_error) result
end
```

`run` is *one-shot only*. Session lifecycle is built on top via `start` + multiple `exec` + `rm` rather than extending `S` with a `start_session` primitive (kept compositional — `Sandbox_session_executor` orchestrates).

Phase 3e items (b)/(c)/(d) above have landed. The one remaining `Docker_client.S` extension is **(a) `run_detached : Keeper_sandbox_session_plan.t -> (Container_name.t, sandbox_error) result`** (see §3.2.3) — added together with `Keeper_sandbox_session_plan` (e) and `Sandbox_session_executor.Make` (f) so the session caller cutover (Phase 4.1) needs no further `S` extension PR.

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
  (** Delegates to [D.run_detached plan] (Phase 3e item (a)). The
      [Real] [run_detached] does the edge work the Plan deliberately
      cannot: writes the plan's [identity_files] ([mkdir_p] +
      atomic write — failure ⇒ a typed error), resolves the seccomp
      choice via [ensure_keeper_sandbox_runtime] (a daemon probe),
      appends the [owner_pid] / [started_at] labels, prepends
      [docker_command_argv ()], assembles the
      [docker run -d --rm --name <plan.container_name> ...] argv from
      the Plan's fields, spawns, and returns the [Container_name.t].
      The [Mock] [run_detached] returns [Ok plan.container_name] with
      no spawn (deterministic — the mock has no daemon). [start] wraps
      that into [t]. *)

  val exec
    :  t
    -> cmd:string
    -> (Docker_response.exec_result, sandbox_error) result
  (** Delegates to [D.exec] against the held container_name, threading
      the session plan's [user] / [workdir] through as [D.exec]'s
      [?user] / [?workdir] (Phase 3e (b), #14947) so a session command
      runs as the same uid:gid / cwd the container was created with. *)

  val cleanup
    :  t
    -> (unit, sandbox_error) result
  (** Delegates to [D.rm]. Idempotent. *)

  val container_name : t -> Container_name.t
  (** Observable for probe/inspect from the caller's POV. *)
end
```

Determinism contract: same `Keeper_sandbox_session_plan.t` ⇒ identical inner one-shot plan ⇒ identical `Container_name.t`. The session handle `t` carries non-determinism (start time, state) but is opaque to callers.

`-d` (detach) is the only `S.run` invocation that produces a session-shaped output (a container id, not an `exec_result`). `D.run` keeps returning `exec_result`; the `-d` *flag* — and all the spawn-time work around it — is `Docker_client.S.run_detached : Keeper_sandbox_session_plan.t -> (Container_name.t, sandbox_error) result` (Phase 3e item (a), ⏳ pending — landing with (e) `Keeper_sandbox_session_plan` and (f) `Sandbox_session_executor.Make` so Phase 4.1 needs no further `S` extension; both `Mock` and `Real` variants together).

`run_detached` is *the edge* — it is where every non-deterministic / I/O concern the `Session_plan` factored out comes back: writing `identity_files`, the seccomp daemon probe, `Unix.getpid ()` / `Unix.gettimeofday ()` for the PID/started_at labels, the `docker_command_argv ()` prefix, and the spawn itself. The `Session_plan` is the pure spec; `run_detached` materialises it; `Sandbox_session_executor` is a thin orchestrator over it (`start` → `run_detached` → wrap; `exec` → `D.exec`; `cleanup` → `D.rm`). This keeps the determinism contract crisp: same `Keeper_sandbox_session_plan.t` ⇒ same argv *modulo* the two spawn-time labels and the resolved seccomp path, ⇒ same `Container_name.t`.

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

These are explicitly **out of scope for v2**; v2 ships against the shipped surface above. The intent block is preserved as a forward marker for the post-Phase-4 cleanup hardening RFC. Underlying call: `docker ps --format '{{json .}}' --filter label=...`. JSON line-delimited. The public `ps_record` above derives only `show`/`eq`; decoding goes through a private `raw_ps_record [@@deriving yojson { strict = false }]` (the `{ strict = false }` tolerates unknown docker fields like `CreatedAt`/`Status`/`Ports`) which is then mapped to `ps_record`. A line that fails to decode is dropped with a stderr warning rather than collapsing the whole listing; a record that decodes but carries an unrecognized `State` token (or, at the `ps_query` level, a non-zero docker exit) surfaces as `Probe_format_drift` — caller sees a typed alert, not a silent miss.

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
| `Keeper_sandbox.t` (closed record, `of_meta`) | Phase 4 callers extract `meta_name` / `cmd` from their `Keeper_sandbox.t` and pass them to `Oneshot_plan.of_request` (which takes `~meta_name:string`, not `Keeper_sandbox.t`, to stay free of cross-module deps — see `keeper_sandbox_oneshot_plan.mli`). The record is preserved unchanged. |
| `Keeper_sandbox_factory.resolve` (memoized per `(in_playground, network_mode)`) | Calls into `Sandbox_executor` in Phase 4 — wiring change only |
| `Keeper_sandbox_containment.check_{read,write}_target` (RFC-0006 Phase B-1) | Continues as host-side defense-in-depth — unchanged |
| `Keeper_lifecycle_hooks` (RFC-0036, on main) | Sibling cleanup path — keeper-level Tombstone_reaped event; NOT the consumer of `cleanup_outcome` (corrected iter 35). Container-level cleanup runs in `Sandbox_cleanup.cleanup_tick` independently. |

## 4. Migration

v2 re-orders Phase 3-5 to gate Phase 4 cutover on Session API delivery. Phases 0-3 shipped before v2 and retain their v1 numbering.

> **Two phase taxonomies appear in this table, deliberately.** The **Phase** column uses *this RFC's* numbering (`0 / 1 / 2 / 3 / 3d / 3e / 3c.2 / 4.x / 5`). The **Status** column references the *PR-series sub-phase tags* used while implementing (`3a`, `3b-iv.2.0–2.5`, `3c.0`, `3c.1`) — those are the labels on PRs #14741…#14889, not RFC phases. Mapping: RFC Phase 1 ↔ PR-tag `3a`; RFC Phase 2 ↔ PR-tags `3b-iv.2.0–2.4`; RFC Phase 3 ↔ PR-tags `3c.0`/`3c.1` (+ `3b-iv.2.5` parser tests). The mismatch is historical, not a contradiction — the PR tags predate this RFC's renumbering.

| Phase | Deliverable | RFC dependency | Risk | Status |
|-------|-------------|----------------|------|--------|
| **0** | `pr-rfc-check.sh` sandbox patterns + bash 3.2 compat | none | done | ✅ `~/me`@`d0add960d7` |
| **1** | `keeper_sandbox_plan.mli` + `docker_client.mli` (signatures, empty stubs) | none | LOW | ✅ Phase 3a #14741 |
| **2** | Plan + Real Docker_client implementations, existing callers unchanged | Phase 1 | LOW | ✅ Phase 3b-iv.2.0–2.4 #14838/14844/14854/14862/14871 |
| **3** | `Sandbox_executor` (oneshot) + `Docker_client.Mock` + parser unit tests | Phase 2 | MEDIUM | ✅ Phase 3c.0/3c.1 #14821/14827, Phase 3b-iv.2.5 #14889 |
| **3d** *(v2)* | Rename `keeper_sandbox_plan` → `keeper_sandbox_oneshot_plan` (file + caller renames; no behavior change). Frees the unqualified name for the Session/Oneshot split. | Phase 3 | LOW — pure rename refactor | ✅ #14934 (2026-05-12) — 14 files, +51/-51, no shape change |
| **3e-b** *(v2)* | `Docker_client.S.exec` gains `?user` + `?workdir` (+ pure `Docker_client_real.exec_argv`) | Phase 3d | LOW | ✅ #14947 (2026-05-12) |
| **3e-c** *(v2)* | `Docker_client.S.info_security_options` (+ pure `Docker_client_real.parse_security_options`) | Phase 3d | LOW | ✅ #14951 (2026-05-12) |
| **3e-d** *(v2)* | `Docker_client.S.image_present` (presence check — narrowed from the earlier `image_inspect → image_info` sketch, §3.0.3) | Phase 3d | LOW | ✅ #14956 (2026-05-12) |
| **3e-e** *(v2; split from 3e-aef in v2.4)* | `Keeper_sandbox_session_plan` — pure session plan: `of_request`, the 7 deterministic labels, `identity_files`, `env_overrides`, `ulimits`. §3.1.2's 4 design questions resolved + pure/edge boundary corrected (v2.3 — `Session_plan` carries the deterministic spec incl. `identity_files`). | Phase 3e-b/c/d | LOW — pure value type + unit tests | ✅ #14970 (2026-05-12) |
| **3e-a** *(v2; split from 3e-aef in v2.4)* | `Docker_client.S.run_detached : Keeper_sandbox_session_plan.t -> (Keeper_container_name.t, sandbox_error) result` + `Mock` (default `Ok plan.container_name`, not fail-closed) + pure `Docker_client_real.run_detached_argv`. The edge: writes `identity_files`, resolves seccomp via `ensure_keeper_sandbox_runtime`, adds PID/started_at labels, prepends `docker_command_argv`, spawns. | Phase 3e-e | LOW — new `S` member, mirrors the `run` wiring | ✅ #14973 (2026-05-12) |
| **3e-f** *(v2; split from 3e-aef in v2.4)* | `Sandbox_session_executor.Make(D : Docker_client.S)` — thin orchestrator: `start` → `D.run_detached` → wrap in opaque session handle (`Container_name.t` + originating plan); `exec` → `D.exec ?user ?workdir ~container ~cmd ()`; `cleanup` → `D.rm`; `container_name : t -> Keeper_container_name.t`. No I/O / clock / Random in the functor — all behind `D`. + unit tests (`Make(Docker_client_mock)`, start/exec/cleanup lifecycle). Phase 4.1 now needs no further `S` extension. | Phase 3e-a | LOW — composition only, no new edge | ⏳ this PR |
| **3c.2** | Cleanup quarantine state machine (`Quarantine.t` + alert path; no `Keeper_lifecycle_hooks` adapter — sibling path per §2 / §3.4) | Phase 3 | MEDIUM | ⏳ pending — Phase 3 is the sole prerequisite (no cross-RFC dependency) |
| **4.1** *(v2)* | Caller cutover `keeper_turn_sandbox_runtime` → `Sandbox_session_executor` (one PR) | Phase 3e-e + 3e-a + 3e-f | MEDIUM | ⏳ pending |
| **4.2** *(v2)* | Caller cutover `keeper_shell_docker:820` → `Sandbox_executor` w/ named one-shot semantics (one PR) | Phase 3 | MEDIUM | ⏳ pending |
| **4.3** *(v2)* | Caller cutover `keeper_sandbox_runtime:838` → `Sandbox_executor` w/ anonymous one-shot semantics (one PR) | Phase 3 | MEDIUM | ⏳ pending |
| **5** | Catch-all removal: remove or justify the 1 residual `try ... with _ -> None` site in `keeper_sandbox_control.ml` (`git_string_opt:306-308`; the 7 git/probe siblings were resolved by the exec_gate migration #14329/#14359 — see §1 F6). Where Phase 4 cutover touches the area, the compiler enforces the migration. | Phase 4.1+4.2+4.3 all merged | LOW — mostly resolved; 1 residual site | ⏳ pending |

**v2 ordering rationale**:
- Phase 4.2 + 4.3 (one-shot caller cutovers) do NOT depend on Phase 3e — they can land in parallel with Session API work. Originally v1 implied a serial order; v2 makes the parallelism explicit.
- Phase 4.1 (session caller) is the only branch that *requires* Phase 3e (specifically 3e-e + 3e-a + 3e-f — `Keeper_sandbox_session_plan` #14970 + `run_detached` #14973 + `Sandbox_session_executor`; like the 3e-b/c/d edge primitives #14947/#14951/#14956, these three shipped one PR each — safe to fragment since none exposed a new layer).
- Phase 5 still gates on all 3 cutovers (compiler exhaustiveness across the subsystem).
- Phase 3c.2 (cleanup quarantine) is independent of Phase 4 — it owns container-level cleanup orthogonal to `Keeper_lifecycle_hooks` keeper-level cleanup. As of iter 35 (2026-05-12) the RFC-0036 cleanup_hook is on main and the dependency is satisfied; Phase 3c.2 is now schedulable independently of Phase 4.

Phases are independently mergeable and revertible. Phase 5 closes the loop by making the old anti-pattern syntactically unwritable in this subsystem.

## 5. Validation

- **Phase 1**: alcotest for type-only signatures (parse + emit JSON for `Sandbox_plan.t` and `Ps_record.t`).
- **Phase 2**: `Keeper_sandbox_oneshot_plan.of_request` property test (qcheck) — `∀ (turn_id, attempt, meta_name, cmd), of_request → Ok` (no panic, no Random). Same input twice → identical plan.
- **Phase 3**: `Docker_client.Mock` driven tests:
  - Daemon-unreachable response → `Daemon_unreachable` propagates to caller, no silent fail.
  - `ps_query` malformed JSON → `Probe_format_drift` typed error.
  - Cleanup loop with 3-fail-then-success → `Clean_quarantine` → `Clean_partial` → `Clean_success` sequence.
- **Phase 4**: integration test running a real `Sandbox_executor.run` end-to-end against a local docker daemon, side-by-side with the legacy path for one keeper persona.
- **Phase 5**: zero `try ... with _ -> None` (or wildcard-only `with`) catch-alls in `keeper_sandbox_control.ml`, except those that re-raise `Eio.Cancel.Cancelled` first. A single-line `rg "try.*with _ -> None"` misses the multi-line `git_string_opt` form (`| Eio.Cancel.Cancelled _ as e -> raise e | _ -> None`), so the check is an AST / multi-line scan rather than a one-line grep.

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
