---
status: reference
last_verified: 2026-06-21
code_refs:
  - lib/keeper_tooling/keeper_tool_execute_shell_ir.ml
  - lib/keeper/keeper_tool_execute_runtime.ml
  - lib/exec_policy/exec_policy.ml
  - lib/config/env_config_core.ml
  - lib/config/env_config_runtime.ml
  - lib/config/feature_flag_registry.ml
  - lib/config/env_config_sandbox.ml
  - lib/tool_resource_gate.ml
  - lib/keeper/keeper_tool_surface_ops.ml
  - lib/keeper/keeper_memory_bank_env.ml
  - lib/workspace/workspace_gc.ml
  - lib/workspace/workspace_utils_paths_backend.ml
  - lib/keeper/keeper_chat_queue.ml
  - lib/keeper/keeper_msg_async.ml
  - scripts/check-feature-flag-consistency.sh
  - scripts/check-ssot.sh
  - scripts/audit-path-ssot.sh
---

# Productization Blockers Adversarial Audit

> Date: 2026-06-21
> Scope: MASC path/env/reimplementation/concurrency/fleet-isolation risks.
> Method: read-only code scan + local guard execution + OCaml 5.x/Eio ecosystem check.
> Status: historical reference. Findings 1 and 7 were superseded on 2026-07-13
> by the RFC-0255 withdrawal of inferred argv path policy.

This audit treats the following as productization blockers:

- local-machine path assumptions that can leak into runtime defaults,
- environment-variable control planes that are too wide or bypass typed config,
- reimplemented infrastructure where MASC already has a central module,
- blocking stdlib filesystem operations on the Eio scheduler path,
- any keeper implementation where one keeper's stall, lock, exception, or switch failure can stop the fleet.

## External 기준

- OCaml 5.4 manual: high-level parallel programming libraries are recommended; domains are heavyweight and should not exceed available cores. Source: <https://ocaml.org/manual/5.4/parallelism.html>
- Eio docs: resources are switch-scoped OS resources; the Eio package already exposes structured `Path`, `Process`, Unix, and executor-pool surfaces. Sources: <https://ocaml.org/p/eio/latest/doc/eio/Eio/index.html>, <https://ocaml.org/p/eio/latest/doc/eio/Eio/Resource/index.html>
- OCaml Discuss Eio cancellation threads: cancellation correctness is a semantic property, not just exception plumbing. Sources: <https://discuss.ocaml.org/t/understanding-cancellation-in-eio/9369>, <https://discuss.ocaml.org/t/i-roughly-translated-real-world-ocamls-async-concurrency-chapter-to-eio/14548>
- Jane Street's public OCaml stack shows the bias expected for large OCaml systems: typed standard libraries, clear async/concurrency abstractions, and centralized reusable components over local parsers. Sources: <https://www.janestreet.com/technology/>, <https://opensource.janestreet.com/>

## Verdict

No runtime `let default_base = "/Users/dancer/me"` style default was found in `bin/` or `lib/`. The serious risk is broader:

1. **Resolved / superseded**: positional argv path inference and its kill-switch
   model were removed; only explicit cwd/redirect validation remains.
2. **P1**: env/config control plane is too wide for a product surface, and its CI guard currently produces false confidence.
3. **P1**: Eio server/keeper paths still perform blocking stdlib directory scans in maintenance and request paths.
4. **P1**: path SSOT guards are ratchets, not strict product gates; at least one split `.masc/config` concat is not caught.
5. **P1**: env parsing is reimplemented in local modules even though central config helpers exist.
6. **P2 monitored**: no current evidence of "one keeper failure stops all keepers" in the first pass, but the codebase has enough shared runtime surfaces that this must remain a P0 review gate.

## Findings

### 1. Positional argv path jail — superseded decision

**Status**: Resolved by removal, not by making the jail unconditional.

The former path jail guessed which argv values were paths and rejected them
before execution. RFC-0255 now records the replacement contract: positional
argv is opaque, while explicit typed `cwd` and redirect targets remain
validated. Process access is bounded by the selected runtime sandbox.

If stronger containment is required, it must be provided by a real sandbox or
capability-owned tool. An environment kill-switch or a renamed argv classifier
must not reintroduce this policy layer.

### 2. Env/config control plane is too wide, and the guard has false negatives

**Severity**: P1.

**Evidence**:

- `docs/runtime-tunables.md:17-19` reports 355 unique knobs and only 21/204 typed getter classifications.
- `docs/runtime-tunables.md:32` documents `MASC_DISABLE_HITL` defaulting to true.
- `lib/config/env_config_core.ml:500-506` implements that default.
- `scripts/check-feature-flag-consistency.sh:24-36` leaves `CALLS` empty, so duplicate-default detection never inspects real calls.
- `scripts/check-feature-flag-consistency.sh:64-68` scans only registry calls plus direct `get_bool` calls in `env_config_core.ml`; it misses direct `get_bool` calls in sibling config modules.
- Local run reports `MASC_KEEPER_DOCKER_PLAYGROUND` as stale, while `lib/config/env_config_sandbox.ml:88` and `lib/config/feature_flag_registry.ml:133` show it is live and registered.
- `lib/config/env_config_runtime.ml:337-339`, `lib/config/feature_flag_registry.ml:202-204`, and `docs/runtime-tunables.md:209` disagree on the `MASC_CDAL_GATE_ENABLED` default text/value.

**Impact**:

This is a product-control problem. A product operator cannot reason about the runtime if hundreds of env knobs are partially classified, comments/docs disagree with registry defaults, and the guard script reports PASS while missing a live module.

**Fix direction**:

- Make `Feature_flag_registry` / typed env definitions the generated SSOT for docs and lint.
- Fail CI when typed env knobs are unclassified, unless explicitly tagged as test-only/internal.
- Fix `scripts/check-feature-flag-consistency.sh` to scan all `env_config*.ml` modules and to populate duplicate-default calls.
- Re-decide `MASC_DISABLE_HITL` default for product mode; if true remains valid for local dev, split local-dev default from product default.

### 3. Blocking stdlib filesystem scans remain on Eio server/keeper paths

**Severity**: P1.

**Evidence**:

- `lib/workspace/workspace_gc.ml:70-87`, `319-340`, and `364-419` use `Sys.readdir`, `Sys.remove`, `Sys.is_directory`, and `Unix.rmdir` inside workspace GC.
- `lib/keeper/keeper_chat_queue.ml:354-371` scans the keepers directory and loads snapshots during persistence setup.
- `lib/keeper/keeper_msg_async.ml:268-291` scans async request records for GC.
- `lib/workspace/workspace_utils_paths_backend.ml:199-209` exposes a shared `list_dir` helper that uses `Sys.readdir` directly for local backends.

**Impact**:

`Workspace_query.safe_yield ()` helps between entries, but it does not make `Sys.readdir` non-blocking. Large directories, slow filesystems, FD pressure, or recursive delete work can still park the OCaml 5/Eio domain. In a multi-keeper runtime, this is a fleet quality issue even when the logical operation is "background cleanup".

**Fix direction**:

- Add a single `Fs_compat.list_dir` / `Fs_compat.fold_dir` abstraction using Eio Path where available, or `Eio_unix.run_in_systhread` / bounded executor pool for blocking stdlib fallbacks.
- Migrate GC, async request GC, chat queue persistence setup, and workspace backend listing through that abstraction.
- Add a lint/ratchet: no new `Sys.readdir` in `lib/server`, `lib/keeper`, or Eio runtime paths without an explicit offload comment.

### 4. Path SSOT guard is a ratchet, not a product gate

**Severity**: P1.

**Evidence**:

- `scripts/check-ssot.sh:65-72` still allows 11 `.masc` concat violations while the local run reports 2.
- `scripts/check-ssot.sh:83-90` still allows 11 config filename literal violations while the local run reports 2.
- `scripts/check-ssot.sh:101-107` allows 9 home-anchored runtime-root mentions.
- `scripts/audit-path-ssot.sh` reports OK, but `bin/main_eio.ml:981` still has split `Filename.concat (Filename.concat base_path ".masc") "config"` that bypasses the audit pattern.
- `docs/rfc/RFC-0267-task-goal-linkage-projection-and-explicit-assignment.md:29` still uses a bare home-anchored runtime-root path in a runtime evidence sentence.

**Impact**:

The repo has correctly moved toward `<base-path>/.masc`, but current gates mostly prevent regressions above stale baselines. A product gate should fail on newly discovered violations and on known-drift baselines that have already dropped.

**Fix direction**:

- Lower `check-ssot.sh` baselines to current counts immediately.
- Upgrade `audit-path-ssot.sh` to catch split concat variants for `.masc/config`.
- Replace remaining docs that imply a shell-home runtime root with explicit `<base-path>/.masc` wording or fully resolved evidence paths.
- Prefer `Common.keepers_runtime_dir_of_base`, `Workspace_utils.masc_dir`, or config-dir resolver APIs over ad hoc concat.

### 5. Env parsing is reimplemented outside the config boundary

**Severity**: P1.

**Evidence**:

- `lib/tool_resource_gate.ml:42-68` defines local bool/int/float env parsers over `Sys.getenv_opt`.
- `lib/keeper/keeper_tool_surface_ops.ml:38-65` defines local TTL parsing over `Sys.getenv_opt`.
- `lib/keeper/keeper_memory_bank_env.ml:14-67` defines a separate keeper-memory env parser family.

**Impact**:

This creates inconsistent parse semantics, inconsistent invalid-value telemetry, and hidden product knobs outside the config catalog. It also makes "what env controls the runtime?" unanswerable without grep.

**Fix direction**:

- Move these readers into `Env_config_runtime` or a shared typed parser module under `lib/config`.
- Require all user/operator-facing env vars to appear in `runtime-tunables.md` from generated metadata, not manual side effects.
- Allow direct `Sys.getenv_opt` only at process bootstrap, secret projection, or test fakes, with comments explaining the boundary.

### 6. Keeper fleet isolation looks improved, but must remain a P0 gate

**Severity**: P2 monitored; P0 if a new shared lock/switch makes one keeper stop all keepers.

**Evidence**:

- `lib/keeper/keeper_msg_async.ml:535-546` fails only the active request switch for cancellation.
- `lib/keeper/keeper_chat_queue.ml:350-371` uses per-entry mutexes after a shared registry read.
- Prior code comments in keeper transition/memory-lane areas indicate known work to avoid shared flush/stall behavior.

**Impact**:

The first pass did not find an active "one keeper dies, all keepers stop" implementation. However, MASC's product promise depends on keeping that invariant hard. Any shared Eio mutex around disk flush, global switch failure path, or exception escaping from per-keeper worker fibers should be treated as P0.

**Fix direction**:

- Add an adversarial test harness that starts multiple keepers, injects cancellation/flush failure in one keeper, and asserts the others continue.
- For shared queues, require per-keeper isolation or bounded async offload with explicit backpressure.
- Use `Switch.on_release` for cleanup tied to a fiber's lifetime; do not rely on catch-all exception blocks for cancellation semantics.

### 7. Shell path descriptor corpus — removed

**Status**: Resolved.

The descriptor, command corpus, flag parser, and per-command exemptions were
deleted. Wrapping guessed argv semantics in a closed type did not make the
classification objective and would have kept MASC coupled to every external
CLI's argument grammar.

## Non-findings from this pass

- No runtime `let default_base = "/Users/dancer/me"` default was found in `bin/` or `lib/`.
- Hardcoded `/Users/dancer/me` occurrences are mostly live-evidence docs, tests, or examples. They still need doc hygiene, but they are not the same as runtime defaults.
- `/bin` and `/usr/bin` defaults exist in host command catalog code; this is a portability/product-packaging issue, not a user-local path leak.

## Verification run

Commands run from the audit worktree:

```text
scripts/check-feature-flag-consistency.sh
scripts/check-ssot.sh
scripts/audit-path-ssot.sh
rg -n 'let default_base\s*=\s*"/Users/dancer/me"|/Users/dancer/me' bin lib test docs scripts
rg -n 'Sys\.getenv_opt|getenv|get_bool ~default|Sys\.readdir|Filename\.concat.*"\.masc"' bin lib scripts docs
```

Verification limitation: the `rg` probes above are rule-based string searches, not AST/typed API checks. They can produce false positives and can miss aliases or wrappers around `Sys.getenv_opt`, direct `Sys.getenv`, `Unix.getenv`, `Unix.environment`, string interpolation, and transformed concatenations such as `Filename.concat base (".masc" ^ suffix)`. Follow-up guards should move these checks toward typed/AST-backed analysis where possible.

Observed guard results:

- `scripts/check-feature-flag-consistency.sh`: PASS, but falsely reports `MASC_KEEPER_DOCKER_PLAYGROUND` as stale.
- `scripts/check-ssot.sh`: PASS/NOTE only; R1 and R4 baselines should be lowered from 11 to 2.
- `scripts/audit-path-ssot.sh`: OK, but misses split concat at `bin/main_eio.ml:981`.

## Recommended PR slices

1. **PR-A: env/feature flag guard hardening**
   - Fix `check-feature-flag-consistency.sh`.
   - Reconcile `MASC_CDAL_GATE_ENABLED` docs/defaults.
   - Add CI failure for unclassified product env knobs.

2. **PR-B: Eio filesystem offload**
   - Add shared Eio-aware/offloaded directory listing in `Fs_compat`.
   - Migrate GC/chat queue/async request/workspace backend scans.
   - Add `Sys.readdir` runtime-path lint.

3. **PR-C: path SSOT gate hardening**
   - Lower stale baselines.
   - Catch split `.masc/config` concat.
   - Replace bare home-root runtime evidence wording.

4. **PR-D: Shell IR path-jail kill-switch sunset**
   - Make Host-profile path-jail non-disableable in product mode.
   - Keep emergency operation explicit, audited, and impossible to enable accidentally.

5. **PR-E: fleet-isolation regression harness**
   - Inject per-keeper failure/cancellation/flush stalls.
   - Assert other keepers keep polling, claiming, and completing work.
