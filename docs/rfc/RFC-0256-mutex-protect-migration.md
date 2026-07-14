---
rfc: "0256"
title: "Migrate hand-rolled Mutex lock/protect/unlock to Mutex.protect"
status: Draft
created: 2026-06-18
updated: 2026-06-18
author: vincent
supersedes: []
superseded_by: null
related: ["0042"]
implementation_prs: [21463]
---

# RFC-0256: Migrate hand-rolled Mutex lock/protect/unlock to Mutex.protect

**Status**: Draft
**Date**: 2026-06-18
**Builds on**: OCaml 5.1 stdlib `Mutex.protect` (async-exception unlock guarantee)
**Related**: PR [#21463](https://github.com/jeong-sik/masc/pull/21463) (Phase 0, `lib/process/`), [#20476](https://github.com/jeong-sik/masc/pull/20476) (out-of-scope `Eio.Mutex.Poisoned` incident), [#20684](https://github.com/jeong-sik/masc/pull/20684) (console-writer stall), [#10682](https://github.com/jeong-sik/masc/issues/10682) (otel EDEADLK diagnostic), [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (no-string-classifier lineage — same philosophy)
**Tracking**: committed inventory in §4 (46 files / 67 classified sites-usages); scratch audit label `mutex-protect-migration-audit` is not a committed workflow.

## 1. Summary

The reconciled inventory in §4 covers **67 classified Mutex sites/usages across 46 files**. **20 files are safe direct-swap quick wins**, **19 files need review**, and **7 files are skip/out-of-scope**. Exactly **5 sites across 4 files** require restructuring (early/conditional unlock, re-entrant lock, or a diagnostic `try/with` coupled to lock acquisition). This RFC gates the **keeper/auth/credential domain (15 files)** — the subset where repo governance requires a cited RFC before an autonomous PR — and defines the full four-phase rollout.

Phase 0 (`lib/process/`, 2 sites) is **complete** (PR #21463, merged 2026-06-17).

## 2. Background

Since OCaml 5.1, `Stdlib.Mutex.protect : 'a Mutex.t -> (unit -> 'a) -> 'a` gives the stdlib-owned lock/body/unlock primitive for mutex cleanup under asynchronous exceptions. The hand-rolled idiom

```ocaml
Mutex.lock m;
Fun.protect ~finally:(fun () -> Mutex.unlock m) f
```

runs its `finally` for ordinary callback returns and exceptions, so the migration is not motivated by synchronous exception behavior. The narrower risk is the async-exception delivery window around the hand-rolled sequence: after the mutex has been acquired but before the `Fun.protect` handler is installed, and around finalizer execution. `Mutex.protect` closes that acquire-to-handler setup gap and performs the unlock path inside the stdlib primitive instead of relying on every caller to assemble the sequence correctly. That matters in this codebase because keeper turns, dashboard refresh fibers, OTel tick fibers, and HTTP handlers run under Eio/domain scheduling.

The deadlock class is not theoretical. The stdlib-mutex evidence for this roadmap is the documented console-writer stall (#20684, `lib/masc_log/console_sink.ml`) and the otel EDEADLK diagnostic path (#10682, `lib/otel_metric_store/otel_metric_store_core.ml`). #20476 is adjacent concurrency history, but it involved `Eio.Mutex.Poisoned` on pool mutexes (`lib/masc_http_client/masc_http_client.ml`), not a stdlib `Mutex.lock`/`Fun.protect` site; this RFC does not claim the stdlib migration remediates that Eio-specific incident. **27 of the 46 files carry at least one `async_exception_benefit=high` site** (deeply Eio-based or documented fiber/domain execution context).

## 3. Proposal (phased rollout)

### Phase 0 — Complete (PR #21463, merged)

`lib/process/exec_tap.ml` `writer` and `lib/process/bg_task.ml` `with_reg`. 2 sites. Behavior-preserving (proof method documented in §7); strictly safer under async exceptions.

### Phase 1 — Quick wins (no RFC required)

Migrate the **19 `migrate_safe` files** in domain-general/log/server/tool/workspace (non-keeper/credential/auth). These are 1-line helper-body swaps or per-site `Mutex.protect` rewrites; all sites are `safe_direct_swap=true` — no early/conditional unlock, no re-entrant lock, no `try_lock`. Open as ordinary PRs, one per file or small batch. Files: `lib/backend/backend.ml`, `lib/dashboard/dashboard_execute_output.ml`, `lib/jsonl_atomic/jsonl_atomic.ml`, `lib/masc_http_client/masc_http_client.ml`, `lib/masc_log/log.ml`, `lib/masc_log/console_sink.ml`, `lib/runtime/dashboard_oas_bridge.ml`, `lib/server/server_routes_http_runtime.ml`, `lib/server/server_routes_http_routes_provider_runs.ml`, `lib/server/server_dashboard_http_link_preview.ml`, `lib/tool_metrics_persist.ml`, `lib/tool_surface/tool_metrics.ml`, `lib/workspace/playground_repo_cache.ml` (stdlib branch only — see §5), `lib/workspace/mention.ml`, `lib/workspace/mention_dedup.ml`, `lib/workspace/workspace_task_cache_invariant.ml`, `lib/subsystem_health.ml`, `lib/llm_metric_bridge.ml`, `lib/dashboard_attribution.ml`.

### Phase 2 — RFC-gated (this RFC)

After this RFC merges, migrate the **15 `needs_review` files** in keeper/auth domains (`lib/keeper/*`, `lib/keeper_runtime/*`, `lib/keeper_tool_call_log.ml`, `lib/auth*`). Each is mechanically the same swap but `rfc_required=true` under repo governance (`CLAUDE.md` `<agent_delegation>`: keeper/credential/auth subsystems require a cited RFC before an autonomous PR). One of these files (`lib/keeper/keeper_prompt_external.ml`) needs a **structural rewrite**, not a direct swap — handled as a Phase 3 blocker.

### Phase 3 — Blockers (restructure)

5 sites across 4 files where the migration is not a literal text swap. Detailed in §5.

### Non-goals

`Eio.Mutex.t` primitives (`Eio.Mutex.use_rw ~protect:true`, `Eio.Mutex.use_ro`) are already cancellation-safe protect equivalents and are **out of scope**. Files whose only Mutex usage is `Eio.Mutex` (`lib/board/board_core.ml`, `lib/board/board_core.mli`) are `skip`. `lib/process/*` is `skip` (Phase 0 complete).

## 4. Classification

Audit by domain (46 files, 67 classified sites-usages):

| Domain | Files | Sites | migrate_safe | needs_review | skip |
|--------|-------|-------|--------------|--------------|------|
| general (lib/* root, backend, dashboard, http_client, multimodal, otel, runtime, subsystem) | 16 | 25 | 9 | 4 | 3 |
| keeper (lib/keeper/*, lib/keeper_runtime/*, lib/keeper_tool_call_log.ml) | 13 | 19 | 0 | 13 | 0 |
| auth (lib/auth*) | 2 | 2 | 0 | 2 | 0 |
| log (lib/masc_log/*) | 2 | 7 | 2 | 0 | 0 |
| server (lib/server/*) | 3 | 5 | 3 | 0 | 0 |
| tool (lib/tool*) | 2 | 2 | 2 | 0 | 0 |
| workspace (lib/workspace/*) | 4 | 5 | 4 | 0 | 0 |
| board (lib/board/*) | 2 | 0 | 0 | 0 | 2 |
| process (lib/process/*) | 2 | 2 | 0 | 0 | 2 |
| **Total** | **46** | **67** | **20** | **19** | **7** |

(Note: `migrate_safe` files = 20 quick wins; `needs_review` = 19 = 15 keeper/auth + 1 multimodal + 1 otel + 2 additional general-review files; the keeper/auth 15 are the RFC-gated subset. Counts are `safe_direct_swap` per-file; individual sites within a needs_review file may still be swappable.)

## 5. Risks — blockers (5 sites / 4 files)

Every non-blocker site is a mechanical swap. The migration requires care at exactly these sites (`safe_direct_swap=false`):

### 5.1 `lib/keeper/keeper_prompt_external.ml:72` and `:84` — early/conditional unlock + re-entrant lock

`get` unlocks `cache_mutex` at line 75 (`Some` branch) and line 78 (`None` branch), then the `None` branch **re-locks `cache_mutex` at line 84** for `Hashtbl.replace`. `Mutex.protect` cannot re-acquire the same mutex inside its body, and cannot match branch-specific early unlocks. **Requires a structural rewrite**: split into two `Mutex.protect` regions — (1) `find_opt` under protect, (2) release the result, perform disk I/O outside the lock, then (3) `Hashtbl.replace` under a fresh `Mutex.protect`. Lines 72 and 84 are only meaningful as part of this single rewrite.

### 5.2 `lib/multimodal/workspace_holder.ml:23` — hand-rolled Mutex.protect with split unlock

`update` (lines 19–27) has an explicit `Mutex.unlock` inside the `with exn` handler (line 23) plus a normal-path unlock (line 27). This is a hand-rolled `Mutex.protect`. Migration to `Mutex.protect mutex (fun () -> workspace_ref := f !workspace_ref)` is semantically equivalent and strictly safer, but requires the reviewer to confirm the `try/with` collapse (the exception-path unlock becomes redundant once `Mutex.protect` owns the region).

### 5.3 `lib/workspace/playground_repo_cache.ml:39` — Eio.Mutex already correct

`Eio.Mutex.use_rw ~protect:true cache_update_eio_mu f` is already the correct protect-style primitive (Eio.Mutex, not `Stdlib.Mutex.lock/unlock`). **Leave the Eio branch unchanged**; migrate only the stdlib fallback at line 29 (which is a separate safe swap, counted in the workspace quick wins).

### 5.4 `lib/otel_metric_store/otel_metric_store_core.ml:31` — diagnostic `try/with` coupled to lock acquisition

`with_lock` wraps lock acquisition in `try Stdlib.Mutex.lock metrics_mutex with Sys_error msg as exn -> ...` (lines 31–37) to capture `last_deadlock_backtrace` and emit `Log.Metrics.error` before re-raising (#10682 EDEADLK diagnostic), then uses `Fun.protect ~finally:unlock f` (line 38). A bare `Mutex.protect metrics_mutex f` silently drops the diagnostic.

**Correct restructure** — wrap the *entire* `Mutex.protect` in the diagnostic `try/with`:

```ocaml
let with_lock f =
  try Mutex.protect metrics_mutex f with
  | Sys_error msg as exn ->
    let trace = Printexc.raw_backtrace_to_string (Printexc.get_callstack 64) in
    let dump = Printf.sprintf "Otel_metric_store.with_lock: %s\nCaller stack:\n%s" msg trace in
    Atomic.set last_deadlock_backtrace (Some dump);
    Log.Metrics.error "Otel_metric_store mutex deadlock: %s" dump;
    raise exn
```

`Mutex.protect` owns lock+body+unlock (async-exception safe); the outer `try/with Sys_error` catches both lock-acquisition failure (EDEADLK) and any `Sys_error` raised by `f`, preserving the diagnostic.

> **Rejected alternative** (correctness hazard): "keep the diagnostic `try/with` around `Mutex.lock`, then `Mutex.protect m f` on the acquired mutex." `Mutex.protect` internally calls `Mutex.lock m`, so passing an already-locked mutex is a **double-lock** — a guaranteed deadlock on the same domain. This alternative must not be used. The scratch audit synthesis suggested this form without reading the body; it is incorrect. The wrap-`Mutex.protect`-in-`try` form above is the only correct one.

(`f` here is metric registration/update — `Hashtbl` membership/add plus `float` writes. It does not raise `Sys_error` in normal operation, so widening the `try/with` scope from lock-only to lock+body has no observable behavioral difference.)

## 6. Verification (per-PR checklist)

- `ocamlformat --check` (parsing/format). This is the minimum local gate when `dune build` is blocked by the `agent_sdk` opam pin (CI then owns type-checking).
- Local `dune build` where the pin permits; otherwise CI Build and Test.
- CI gates green: Build and Test, Lint, Meta Guards, Dashboard.
- **Deadlock is not caught by unit tests** unless a test deliberately drives the re-entrant / async-exception path. Behavior preservation must be proven by code inspection using the method in §7, not asserted from a green test run.

## 7. behavior-preserving proof method (reusable)

Each migration PR establishes behavior preservation by:

1. **Identical lock sequence.** `Mutex.protect m f` and the hand-rolled `lock m; f (); unlock m` perform the same lock/unlock order. Both run on OCaml's non-recursive `Mutex`, so same-thread re-acquisition deadlocks identically in both. Therefore: *if the original had no re-entrant deadlock, the migration has none.*
2. **Definition-order re-entry exclusion.** OCaml's sequential `let` binding forbids forward references. A callback defined *before* the mutex and its wrapper (e.g. `release_lifetime_guard`, `mark_process_finished` in `bg_task.ml`, defined before `registry_mu`/`with_reg`) cannot reference them in its body — the re-entry path is structurally impossible. Use this to discharge whole classes of callbacks without reading their bodies.
3. **Direct mutex-reference census.** `rg "<mutex>"` to confirm direct `Mutex.lock`/`unlock`/`protect` references are exactly `create` + the wrapper definition (two sites). If the wrapper is the sole access path, re-entry risk reduces to "a callback re-invokes the wrapper."
4. **Callback re-invocation trace.** For callbacks defined *after* the wrapper (and for inline lambdas), read the body and confirm no wrapper re-invocation and no direct mutex re-lock. Functions annotated `(* Called under [<mutex>] *)` are the primary suspects.
5. **Empirical evidence.** The original hand-rolled pattern runs in production; the absence of a live deadlock is evidence the re-entry invariant holds. Identical lock sequence ⇒ the migration inherits that invariant.

Phase 0 (`bg_task.ml`/`exec_tap.ml`) was discharged with this method: `registry_mu` direct references were only `create` (191) and `with_reg` (196); callbacks defined before 191 were excluded by definition order; `poll_state` (defined after, 367) was read and confirmed to have no `with_reg` re-invocation.

## 8. References

- OCaml 5.1 `Mutex.protect` — https://ocaml.org/manual/latest/api/Mutex.html
- OCaml `Fun.protect` finally semantics and async-exception caveats — https://ocaml.org/api/Fun.html
- PR #21463 (Phase 0, merged) — `lib/process/` Mutex.protect migration
- #20684 (console-writer stall), #10682 (otel EDEADLK diagnostic), #20476 (adjacent `Eio.Mutex.Poisoned` history; out of scope for stdlib mutex migration)
- `CLAUDE.md` `<agent_delegation>` — keeper/credential/auth subsystem RFC gate
- `mutex-protect-migration-audit` scratch label (data source name only; not a committed workflow or tool)
