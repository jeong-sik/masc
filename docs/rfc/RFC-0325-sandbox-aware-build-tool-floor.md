# RFC-0325: Sandbox-aware build-tool floor (dune) + actionable host redirect

**Status**: Draft
**Date**: 2026-07-08
**Builds on**: [RFC-0254](./RFC-0254-shell-ir-approval-autonomous-policy.md) (autonomous approval policy + catastrophic/privileged floor), [RFC-0255](./RFC-0255-shell-ir-path-typed-scope-and-floor-narrow.md) (floor narrowing), [RFC-0005](./RFC-0005-typed-capability-substrate.md) (typed capability substrate)
**Related**: [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md), [RFC-0088](./RFC-0088-counter-as-fix-result-propagation.md) (no-string-classifier lineage), [RFC-0199](./RFC-0199-evidence-driven-auto-approval.md)
**Tracking**: issue #23685

## 1. Summary

A keeper (`issue_king`) running `dune build lib/keeper/keeper_approval_queue.ml`
was hard-blocked with `privileged command 'dune' requires explicit approval; no
Shell IR approval resolver is configured, so it is blocked`
(`approval_required_kind=privileged_program_floor`), and the deterministic retry
was skipped (`deterministic_error_policy_blocked`). The keeper could not build or
verify any code.

Investigation found three distinct layers, not one:

1. **Silent Docker→Host fallback.** The keeper requested `sandbox_profile=docker`
   but the docker image was absent, so `docker_local_fallback_target`
   (`keeper_sandbox_shell_ir_target.ml:134-149`) silently fell back to Host
   execution. The keeper had no signal it was outside a container. *(Out of
   scope here — see §7; tracked separately.)*
2. **Dead-end block message.** On Host, blocking bare `dune` is correct, but the
   typed Shell IR floor emits a terminal "no approval resolver" message instead
   of the actionable rewrite (`Run scripts/dune-local.sh build <target>`) that
   `Exec_policy.Direct_dune_invocation` already produces
   (`keeper_tool_execute_readonly_policy.ml:60-68`).
3. **Sandbox-blind floor.** The privileged-program floor
   (`keeper_tool_execute_shell_ir.ml:247-259`) ignores the resolved `~sandbox`.
   Inside a real container, bare `dune` is safe (isolated `_build`, isolated fd
   table, container contains dune-rule arbitrary execution) and `dune.3.22.0` is
   pre-installed (`Dockerfile.keeper-sandbox:38-43`) — yet it is blocked
   identically to Host.

This RFC covers layers 2 and 3, keyed on the **resolved** `Sandbox_target`, and
removes the string-classifier SSOT violation in dune detection.

## 2. Why bare dune is blocked (the justification is Host-only)

`keeper_tool_execute_readonly_policy.ml:64-66`:

> "Bare dune bypasses scripts/dune-local.sh and can create concurrent local
> builds that exhaust host file descriptors."

The three concrete hazards:

| Hazard | Host | Real container |
|---|---|---|
| Shared `_build` corruption (fleet shares one host checkout) | real | isolated per container → n/a |
| Host fd exhaustion (ENFILE/EMFILE) | real | per-container fd table → n/a |
| dune-rule arbitrary code execution | real (no jail) | the container *is* the jail |

RFC-0254 §1 applies the floor to both Host and Docker "as defense-in-depth"
**for the catastrophic class** (force-push, mkfs) that "can still reach real
credentials/remotes". `dune build` is not that class — it touches no remote or
credential; its only risk (arbitrary exec) is exactly what the container
contains. So the defense-in-depth rationale does not extend to dune.

## 3. Current detection is a string classifier duplicated against the registry

Two independent places decide "this is dune":

- `Exec_program` closed registry (`exec_program.ml:148-260`) does **not** list
  `dune` (only `dune-local.sh`, `make`, `cmake`). So bare `dune` → unknown →
  `Privileged` (fail-closed, `exec_program.ml:395`).
- `shell_command_gate.ml:249-255` `command_runs_dune` does
  `String.equal bin "dune"` (plus `env dune`, `opam exec … dune` wrappers) to
  set `direct_dune_seen`.

This is the exact "string/substring classifier where a typed variant is possible"
anti-pattern (RFC-0042/0088; CLAUDE.md "노 스트링 매치"). The two paths can drift:
the registry says "unknown", the gate says "dune", and neither is the single
source of truth.

## 4. Decision

### 4.1 Classify `dune` in the typed registry (SSOT) — identity only, not risk downgrade

Add `Dune` to `Exec_program.known` so the typed Shell IR path recognises `dune`
by **variant**, not by absence. `direct_dune_seen` / `command_runs_dune`
(`shell_command_gate.ml:249` `String.equal bin "dune"`) become derivable from
the typed program identity; the string matcher is retired (or reduced to the
`env`/`opam exec` unwrap that resolves to the typed program, not a bare
`String.equal`).

**Risk class stays `Privileged` (NOT `Audited`).** This is load-bearing:
under the autonomous overlay `Audited → Allow` (RFC-0254 §5), so classifying
`dune` as `Audited` would let bare `dune` bypass the floor and run on **Host**
too — destroying the host build-lock invariant §4.2 preserves. The `Dune`
variant exists only to give the floor a typed handle; the allow/deny decision is
made by the §4.2 floor rule, not by `risk_class`. (Contrast `make`/`cmake`,
which are `Audited` because they have no shared-`_build`/host-fd hazard requiring
serialization through a lock wrapper.)

### 4.2 Floor decision keys on the resolved `Sandbox_target`

`dispatch_classified` already receives `~sandbox` (the resolved target, computed
*after* the Docker→Host fallback). The build-tool rule:

- `~sandbox = Docker _` (genuine container): `dune` executes directly
  (`Audited` → autonomous `Allow`). No wrapper, no floor block.
- `~sandbox = Host` (incl. Docker-requested-but-fell-back): `dune` is **not**
  executed directly. Return an actionable typed rejection carrying the existing
  `Direct_dune_invocation` rewrite: "Run scripts/dune-local.sh build <target>
  from the repo root." This preserves the host build-lock invariant.

Because the decision uses the *resolved* target, a Docker request that fell back
to Host is treated as Host — the fallback cannot be used to reach bare dune on
the host.

### 4.3 No new approval resolver

Earlier discussion considered wiring an `Ask`/HITL resolver (RFC-0254 §2.2
defect #1). Rejected for this domain: a build tool needs no human. The correct
resolution is deterministic (container → allow; host → redirect to the locked
wrapper), consistent with RFC-0254's "no `Ask` in the autonomous lane".

## 5. Non-goals

- Wiring a general Shell IR approval resolver (RFC-0318/0319 territory).
- Changing the catastrophic floor (force-push, mkfs) — unchanged on both
  profiles.
- Fixing the Docker→Host fallback provisioning (layer 1) — see §7.

## 6. Verification

- **Build:** `DUNE_CACHE=disabled dune build --root .` (CI; the
  `lib/exec`/`lib/exec_policy`/`lib/keeper` boundary has stale-cmx risk — full
  build, not `@check`).
- **Tests (typed, no string round-trip):**
  - `Exec_program.of_string "dune"` → `known = Some Dune`, `risk = `Privileged`
    (identity added; risk deliberately NOT downgraded — see §4.1).
  - Floor with `~sandbox:(Docker …)` + bare `dune` → `Allow` (executes).
  - Floor with `~sandbox:Host` + bare `dune` → typed rejection whose rewrite is
    `scripts/dune-local.sh build …` (assert the rewrite string comes from the
    `Direct_dune_invocation` SSOT, not a new literal).
  - `env dune build` / `opam exec -- dune build` resolve to the same typed
    program and same disposition.
  - Catastrophic floor regression: `git push --force` still `Deny` under both
    profiles.
- **Behavior:** keeper on host-fallback receives the rewrite and can proceed via
  `scripts/dune-local.sh`; keeper in a real container builds with bare `dune`.

## 7. Follow-ups (separate)

- **Layer 1 (provisioning):** why the docker image was absent, and whether a
  silent Host fallback for a Docker-profile keeper is acceptable or should be a
  visible degraded-state signal. Tracked in issue #23685.

## 8. Risks / trade-offs

- Adding `dune` to the closed registry widens the enum; every exhaustive match
  over `Exec_program.known` must add the arm (compiler-enforced — the point).
- Keying on resolved `~sandbox` assumes the resolved target is trustworthy. It is
  computed by `keeper_tool_execute_runtime.ml:801-826` before `dispatch_classified`
  and is the same value used for actual dispatch, so "allow in Docker" and "run
  in Docker" cannot diverge.
- If a future container image ships without dune, `dune` inside it would fail at
  exec time (command-not-found) rather than being redirected — acceptable
  (honest failure), and `Dockerfile.keeper-sandbox` currently guarantees dune.
