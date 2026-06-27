# RFC-0255: Shell-IR Path Policy — Typed Path-Scope, Read/Write Asymmetry, and Catastrophic-Floor Narrowing

**Status**: Draft
**Date**: 2026-06-18
**Builds on**: [RFC-0208](./RFC-0208-shell-ir-compositional-risk-ast.md) (Shell IR compositional risk / path policy), [RFC-0254](./RFC-0254-shell-ir-approval-autonomous-policy.md) (autonomous approval policy + catastrophic floor)
**Resolves**: RFC-0254 §13 Q1 (floor membership for local destructive git), Q4 (typed Path-scope replacement of the string path heuristic), Q5 (read/write asymmetry of the path jail)
**Related**: [RFC-0005](./RFC-0005-typed-capability-substrate.md) (typed capability substrate), [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (no-string-classifier lineage), [RFC-0088](./RFC-0088-counter-as-fix-result-propagation.md)
**Tracking**: TBD (must be assigned before P1 — see §6, kill-switch removal obligation)

> Line anchors below are approximate (`~`): they were read at the worktree HEAD `61481411cd` and may drift by a few lines. Function names, not line numbers, are authoritative.

## 1. Summary

The shell-IR path jail (`Exec_policy.validate_shell_ir_paths`) decides whether a command's path arguments stay inside the keeper workspace. It detects "which argument is a path" with a **string heuristic** — `looks_like_path_token` treats any non-URL token containing `/` as a filesystem path (`exec_policy.ml:~339`) — and then carves out per-command exemptions one binary at a time (`git_revisionish_token`, `exec_policy.ml:~356`; `gh_endpointish_token`, `exec_policy.ml:~390`, added by PR #21462).

This has two measured consequences:

1. **False rejection of routine read/exploration commands.** Keeper commands such as `ls -la /Users/dancer/me/`, `cat ../../../docs/library/x.md`, `find /Users/dancer/me -maxdepth 4 …` are rejected with `Path blocked: <path> (outside allowed directories for this keeper command)` because their arguments resolve above the keeper's worktree, even though they are read-only. Measured (`<base-path>/.masc/logs/system_log_2026-06-17.jsonl`, one day): **`shell_ir path_reject` WARN lines = 28; `Path blocked` rejection messages = 111** (the two differ because a single rejection is logged at the WARN audit line and again in the error payload; `path_reject` ≈ 28 is the per-command count). `policy_denied` (approval-floor Deny) = **0** in the same window — the block was the path jail, not the catastrophic floor.
2. **Workaround accretion.** Each over-cut binary gets its own string exemption: `git` (`git_revisionish_token`), then `gh` (#21462). This is the N-of-M pattern CLAUDE.md's workaround bar names — the heuristic over-matches, and the fix is "exempt the next binary" (`sed`, `curl`, `python3`, … remain open). PR #21468 then *widened* the adjacent catastrophic floor (`has_short_flag` so `clean -fd`/`push -fv` Deny) — the opposite of RFC-0254 §10's "narrow the floor" prescription.

The typed substrate to fix this **exists in name but is not soundly wired**: `Path_scope.t` (`path_scope.ml:~1-10`) and `Capability.Read_path`/`Write_path` constructors (`capability.ml:1-7`) exist, but `Capability_check.of_ir` produces them only from **redirects**, never positional argv (`capability_check.ml:~36-49`); and even the redirect-derived scopes are classified against a hardcoded `~cwd:"."` placeholder (`bash_subset.mly:~10`), so their `Inside/Outside_workspace` field is meaningless. The jail therefore **discards the typed scope and re-validates the raw string** with the real `~workdir` (`exec_policy.ml:~697`). The "already-classified scope" is not actually correct — see §4.

This RFC specifies:

- **§4.1 / §4.2** Produce **cwd-correct** typed `Path_scope` capabilities for positional argv at the IR boundary, and have the jail consume them — retiring `looks_like_path_token` and the per-binary exemption ladder. This requires threading the keeper cwd/mapped-roots into a currently cwd-blind producer (the obstacle the first draft under-stated).
- **§4.3** A read/write asymmetry: read-only commands scoped more permissively than mutating commands — **gated on a typed `Sensitive_path` deny-list landing in the same change** (RFC-0254 §13 Q5).
- **§4.4** Reconcile the two notions of "inside workspace" (`Path_scope.classify`'s cwd-relative one vs the jail's keeper-repo-mapping rule), noting this also perturbs the already-shipped floor's `find_write_escape`.
- **§4.5** Keep raw destructive git in the trust-independent floor unless the command path proves recovery preconditions first. `reset --hard` and `branch -D` are only conditionally recoverable, so the raw commands stay floored; future structured recovery tooling may narrow them after clean-worktree/snapshot/reachability checks. Resolves RFC-0254 §13 Q1 conservatively.
- **§4.6** Add a path-jail kill-switch (the jail has none; §2.4) — a safety valve with an explicit removal obligation, not a fix.

## 2. Context & problem

### 2.1 How the jail decides today (code-verified 2026-06-18)

`validate_shell_ir_paths ?keeper_id ?base_path ?workdir shell_ir` (`exec_policy.ml:~631`):

1. `workdir = None` → `Ok ()` (jail disabled). Keepers always thread `~workdir = cwd` (`keeper_tool_execute_runtime.ml:~429`), so this branch is never taken for a keeper.
2. `validate_simple` extracts `command_name = basename bin` and literal argv (`exec_policy.ml:~711`). Non-literal argv (`Var`/`Concat`) skips the whole check.
3. `path_argument_values` strips flags / regex patterns / redirect operators, returning candidate positional tokens (`exec_policy.ml:~500`); `command_materializes_path_arg` (`exec_policy_path_arg_descriptor.ml:~56-60`) decides which commands have path-bearing positionals.
4. Per-token ladder (`exec_policy.ml:~666-693`): inline `--x=path` → `is_path_flag` next-token → `git` revisionish exempt → `gh` endpointish exempt → **`looks_like_path_token` → `validate_path_value`** → else skip.
5. `validate_path_value` → `Paths.validate_path` (`exec_policy_paths.ml:~103-126`); false → `Error (Path_outside_whitelist { for_keeper_command = true })`, rendered as the observed message by `Keeper_path_check_error.to_message` (`keeper_path_check_error.ml:~18-24`).

### 2.2 The whitelist, and why routine reads escape it

With `workdir = Some wd`, a resolved path is allowed iff it is under `/tmp`, under the keeper's own `wd`, under the repo root above a `.worktrees/` workdir, or under a registered repo the keeper is mapped to (`exec_policy_paths.ml:~116-119`). Containment is a strict prefix test (`exec_policy_paths.ml:~51`). Therefore:

- `ls -la /Users/dancer/me/` — the second-brain root is the **parent** of the keeper worktree, not under it; the worktree path has the root as a prefix, not vice versa → outside.
- `cat ../../../docs/library/x.md` — `resolve_path` normalizes `../` against `wd`, landing above the repo root → outside.
- `find /Users/dancer/me …` — `find` is path-materializing; the absolute root is outside.
- `gh api /repos/owner/repo/check-runs` — leading-`/` endpoint matches `looks_like_path_token`. PR #21462 added `gh_endpointish_token` (`exec_policy.ml:~390`) to exempt it; from source the leading-`/` form **is** exempted. The 2026-06-17 14:xx UTC `gh` rejections in the log predate the current server process (`ELAPSED ≈ 18 min` at observation vs log timestamps hours earlier), so they are attributed to a pre-#21462 instance. `gh` is thus the *first* N-of-M exemption, not an open defect — do not "fix gh again" (§9 Option D).

### 2.3 The string heuristic is a classifier the compiler cannot check

`looks_like_path_token` answers "is this argument a path?" with `String.contains token '/'` plus hand-maintained per-binary exceptions. A new binary whose arguments contain `/` but are not paths (a `sed` address `/^foo/d`, a scheme-less `curl host/path`, an `npm` scoped package `@scope/pkg`) is misclassified until someone adds the next `*_token` exemption. There is no closed type forcing every such case to be considered (RFC-0042 lineage).

### 2.4 The jail has no kill-switch

`MASC_SHELL_IR_APPROVAL_GATE_ENABLED` (default `true`) toggles only the *approval* gate. **Both** branches of `keeper_tool_execute_runtime.ml:~406` call `dispatch_classified`, which unconditionally runs `validate_paths` (`keeper_tool_execute_shell_ir.ml:~120-123`; the approval branch delegates to the same on Allow, `~191-207`). A search for an independent flag found none. The only source-level disable is the `workdir = None` branch, which keepers never hit. **`path_reject` cannot be disabled without a rebuild** — there is no operational mitigation for a path-jail false-positive storm. This is the gap that turned the merge into a hard stall with no env-level escape hatch.

### 2.5 Read = write today

`command_materializes_path_arg` lumps read-only `cat`/`ls`/`find`/`grep`/`head`/`tail`/`nl`/`rg`/`sed`/`stat`/`tree`/`wc` into the same set as mutating commands (`exec_policy_path_arg_descriptor.ml:~56-60`), and all candidate tokens take the same `validate_path_value ~requires_existing_dir:false` against the same whitelist. A keeper reading a sibling doc and a keeper writing outside the workspace are treated identically. RFC-0254 §13 Q5 flagged this asymmetry; it is the reason read-only exploration is as jailed as mutation.

> Note: today the descriptor is a **coarse boolean** — it says "this command has path positionals", not *which slot* or *read vs write*. Per-slot direction metadata does not exist and must be authored for §4.1/§4.3 (this is net-new, not a relocation — see §4.1).

### 2.6 The catastrophic floor over-includes local destructive git — but not all of it is recoverable

`catastrophic_floor` Denies any `Git_op.Destructive` regardless of overlay (`approval_policy.ml:~100-102`). `git_op.ml:~50-77` classifies `branch -D`, `stash drop`, `push --force/-f`, `reset --hard`, `clean -f`, `worktree remove` as Destructive. Recoverability is **not uniform**:

| op | recoverable? | how |
|---|---|---|
| `push --force` / `push --delete` | **No (remote-irreversible)** | remote ref overwritten/deleted; no local undo |
| `clean -f[d]` | **No** | deletes **untracked** files — in no commit, no reflog |
| `worktree remove` | **No (effectively)** | discards uncommitted worktree state; in this repo other keepers/the conveyor mutate worktrees concurrently (externally-active HEAD) |
| `reset --hard` | **Partial** | prior HEAD in reflog, but uncommitted tracked changes are not recoverable |
| `branch -D` | **Conditional** | branch tip may be recoverable, but only after proving reachability/no active worktree or snapshotting |
| `stash drop` | partial | dangling commit; `git fsck` only |

RFC-0254 §10 prescribes narrowing the floor; §13 Q1 left membership open. The naive "demote all local destructive git" is **wrong**: `clean -fd` and `worktree remove` cause irrecoverable loss and must stay floored, and raw `reset --hard` / `branch -D` do not prove the stateful recovery preconditions needed for autonomous execution. (`destructive_operation_blocked` in the logs is a *different*, pre-existing deterministic guard in `keeper_tool_deterministic_error.ml`, ~62–107/day with no merge-correlated change — out of scope here.)

## 3. Design principle

Parse, don't validate (Alexis King) + Simple Made Easy (Hickey): "is argument *i* a path, read or write?" must be answered **once**, at the IR boundary, by a total function producing a typed `Path_scope` capability — not re-derived from strings at the policy layer with a growing exemption list. The jail then consumes typed capabilities and never sees a raw token. **Crucially, that single classification must run with the real keeper cwd/mapped-roots** — the current code classifies redirects against `~cwd:"."` and re-does the real decision downstream as a string, which is the duplicate-classification the typed approach must eliminate (RFC-0254 §5.4).

## 4. Design

### 4.1 Cwd-correct typed path-capability production (resolves §13 Q4, producer half)

`Path_scope.classify` requires `~raw ~cwd` (`path_scope.ml:~83`), but `head_cap (bin) (args)` and `of_ir : Shell_ir.t -> Capability.t list` carry **no cwd and no keeper mapped-roots** (`capability_check.ml:~20,~51`). So this is **not** "extend `of_ir` to emit caps"; it is a **signature change** to `of_ir`/`of_simple`/`head_cap`/`redirect_cap` adding `~cwd` (and the keeper's mapped repo roots), threaded from every caller (`keeper_tool_execute_shell_ir.ml:~191`, `exec_core.ml:~327`). With cwd available, the producer emits `Read_path scope` / `Write_path (scope, mode)` for positional path arguments, where `scope.scope` is classified against the real workspace.

Two sub-tasks the first draft under-stated:

- **Net-new per-slot metadata (§2.5).** `command_materializes_path_arg` is a coarse boolean; the producer needs to know *which positional slot* of `find`/`sed`/`tar`/`cp`/`cat`/`ls` is a path and its read/write **direction**. This metadata must be authored, not relocated.
- **Cross-library ownership.** The descriptor lives in `masc_exec_policy` (depends on `masc_exec`); the producer lives in `masc_exec`. Moving the corpus into the producer reverses a dependency-direction boundary and risks the stale-cmx cross-lib link issue (§7). Resolve ownership (likely: the corpus moves down into `masc_exec` as pure data) **before** P3.

Tokens that are *not* paths (a `gh` endpoint, a `sed` address, a scoped npm package, a scheme-less URL) are simply **not emitted as path capabilities** — excluded by construction, which is what retires the `*_token` exemption ladder.

### 4.2 Jail consumes cwd-correct typed scopes (resolves §13 Q4, consumer half — inseparable from §4.4)

`validate_shell_ir_paths` is rewritten to fold over the command's `Path_scope` capabilities instead of re-scanning argv strings. Removed: `looks_like_path_token`, `git_revisionish_token`, `gh_endpointish_token`, and the string ladder. **This is not "consume already-classified scopes"** — because the existing scopes are classified against `~cwd:"."` (`bash_subset.mly:~10`) and the jail today discards them and re-validates the raw string (`exec_policy.ml:~697`). The scopes must first be *re-produced with the real cwd* (§4.1). Therefore §4.2 and §4.4 are **one change**, not separable phases.

### 4.3 Read/write asymmetry (resolves §13 Q5) — gated on a typed deny-list

The jail decision becomes a function of capability *kind*:

- `Write_path (scope, _)` — must be inside the keeper workspace (current strictness for mutation; unchanged).
- `Read_path scope` — permitted over a **wider** boundary (second-brain tree / parent docs / mapped repos), unblocking `ls`/`cat`/`find`/`grep` over workspace-parent paths.

**Hard prerequisite (security):** widening reads is unsafe without a typed `Sensitive_path` deny-list, and it must land in the **same change**. Today the `.masc/` guard (`shell_command_gate.ml:~69-73`) matches **relative tokens only** (`.masc/`, `./.masc/`); an absolute `cat /Users/dancer/me/.masc/keeper/<other>/…` is blocked **solely by the path jail this section loosens**. So §4.3 must introduce a typed `Sensitive_path` scope (credential files, other keepers' `.masc/` state, host secrets) that denies reads regardless of the widened boundary. No widening ships without it.

### 4.4 One notion of "inside workspace" (§13 Q4 reconciliation — and it touches the shipped floor)

`Path_scope.classify` (`path_scope.ml:~83-99`) classifies relative to `cwd` and does not know the jail's keeper-repo-mapping + `.worktrees/` repo-root rule (`exec_policy_paths.ml:~67-101`). Unify into one source of truth (keeper-repo-mapping is authoritative), parameterizing `classify` by the keeper's mapped roots.

**Coupling the first draft missed:** `find_write_escape` — the *already-shipped* catastrophic floor's write guard — already pattern-matches on `Path_scope.scope` (`Outside_workspace`/`Absolute_unknown` ⇒ escape, `approval_policy.ml:~43-49`). Re-parameterizing `classify` changes what `Inside_workspace` means **for the floor too**, plus existing callers (`exec_shell_adapter.ml:~8`, `keeper_tool_execute_shell_ir.ml:~16`, `bash_subset.mly:~10`). §4.4 is therefore not isolated to producer+jail; it perturbs the floor and must be verified against `find_write_escape`'s existing behavior.

### 4.5 Catastrophic-floor narrowing — irreversibility, not locality (resolves §13 Q1)

Split `Git_op.Destructive` by **recoverability** (§2.6), not by local/remote:

- **Stay floored (trust-independent Deny):** `push --force`, `push --delete` (remote), **`clean -f[d]`** (untracked deletion, not in reflog), **`worktree remove`** (uncommitted/shared worktree loss), **`reset --hard`** (uncommitted tracked changes are not in reflog), **`branch -D`** (requires reachability / active-worktree proof).
- **Future narrowing path:** expose a structured recovery operation that first proves a clean/snapshotted worktree, no active worktree for the target branch, and branch-tip reachability from an accepted ref or explicit recovery record. Only that structured path may be overlay-graded.
- **Open (§11):** `stash drop` (dangling-commit only) — default keep floored until decided.

> **Implementation caveat (M1).** The RFC-0254 claim "the compiler forces every match site" did **not** hold at the floor: `find_destructive_git` used `Git_op.Destructive _ as g` with a `_ :: rest` catch-all under `[@@warning "-4"]`. This PR keeps raw destructive git floored and adds a closed `git_is_floored : Git_op.t -> bool`, so a future top-level `Git_op.t` constructor must receive an explicit floor decision instead of falling through the capability scan.

### 4.6 Path-jail kill-switch (historical valve, sunset at P5)

Historical P1 introduced `MASC_SHELL_IR_PATH_JAIL_ENABLED` (default `true`, re-readable per process) gating `validate_shell_ir_paths`, so a path-policy false-positive could be disabled without a rebuild — symmetric with the approval-gate kill-switch.

> **Security note (M2).** Disabling this flag removes the **only positional write-escape guard** on the Host profile: `find_write_escape` inspects `Capability.Write_path`, which is emitted only from **redirects**, never positional argv (`capability_check.ml:~36-41`). So a positional write-escape (`cp ../../x /tmp`, `mv` outside the workspace) is caught by nothing but the path jail. Turning the flag off trades write containment for read relief — acceptable as a short-lived valve, not a steady state.

**P5 sunset status:** the flag has been removed. Product runtime always calls `Exec_policy.validate_shell_ir_paths`; a path-policy false-positive now requires a policy/data fix or rollback, not an operator env override. The temporary valve was removed; the path jail graduated into the permanent defense.

## 5. Non-goals

- **Network-egress / exfiltration containment** — unchanged from RFC-0254 §6; the path jail is filesystem scope, not network.
- **Replacing the keeper-repo-mapping authorization model** — §4.4 unifies *classification*, not *authorization* of which repos a keeper may touch.
- **Removing the approval floor** — RFC-0254's floor stays; this RFC narrows its git membership by recoverability (§4.5) and fixes the orthogonal path layer.

## 6. Implementation plan

1. **P1 — kill-switch (§4.6, historical).** Smallest, unblocks operations. Flag + gate + `removal target: P5` + tracking issue. Shipped first so a regression had an env-level mitigation.
2. **P2 — floor classifier hardening (§4.5).** Keep raw destructive git floored, add the closed `git_is_floored` classifier so future `Git_op.t` arms cannot fail open, and document the structured-recovery preconditions required before any future narrowing of `reset --hard` / `branch -D`. Tests per §4.5. Self-contained in `lib/exec`.
3. **P3+P4 — typed cwd-correct producer + jail consumer, ATOMIC (one PR) (§4.1–4.4).** Thread cwd/mapped-roots through the producer; author per-slot direction metadata; resolve cross-lib ownership; rewrite the jail to consume typed scopes; **land the `Sensitive_path` deny-list (§4.3) in the same PR as the read widening**; delete `looks_like_path_token`/`*_token`. P3 and P4 must not land separately — a half-migrated state runs two classifiers (the RFC-0254 §5.4 anti-pattern). Reconcile `find_write_escape` (§4.4).
4. **P5 — verification (§7) + remove the kill-switch.** The path jail graduated to the only product path; the env-level off-switch did not.

P1+P2 resolve the *floor* and the *operational gap* quickly; P3+P4 are the structural root fix and ship as one coherent, atomic change.

## 7. Verification

- **Property test:** routine keeper read commands (`ls`/`cat`/`find`/`grep`/`gh api`/`git -C`) over workspace-parent and mapped-repo paths → no `Path_reject`; reads of `Sensitive_path` (other keepers' `.masc/`, credentials, both relative AND absolute) → denied; writes escaping the workspace → `Path_reject`.
- **Floor tests (§4.5):** `push --force`/`clean -fd`/`worktree remove`/`reset --hard`/`branch -D` → `Deny` under every overlay incl. autonomous. Future structured recovery tooling must get separate tests for its preconditions before it can be overlay-graded.
- **TLA+ bug-model** (repo spec-mutation pattern, RFC-0254 §9): model jail as read/write × inside/outside; `BugAction` = out-of-workspace **write** reaching `Allow`; invariant `WriteEscapeNeverAllowed`. Second invariant `SensitiveReadNeverAllowed`. Clean passes; `-buggy.cfg` violates.
- **No-duplicate-classifier check:** assert (test or grep-gate) that after P4 `looks_like_path_token` and the `*_token` exemptions are *deleted*, not bypassed.
- **Build:** `DUNE_CACHE=disabled dune build --root .` in the worktree — the `lib/exec`/`lib/exec_policy`/`lib/keeper` boundary has produced stale-cmx cross-lib link issues; full cache-disabled build required, not just `@check`.

## 8. Rollout

- P1 kill-switch shipped first as a historical mitigation valve. At P5 the env-level mitigation is removed; if a live false-positive storm recurs, operators should roll back or patch policy/data rather than disabling the path jail.
- P3+P4 graduated behind the same flag historically: land honoring the flag, soak, then make typed-scope the only path; remove the kill-switch at P5.
- Post-enable verification (`<base-path>/.masc/logs/system_log_*.jsonl`): `path_reject` should drop to genuine write-escapes; `policy_denied` should show raw destructive git (`push --force`/`clean -fd`/`worktree remove`/`reset --hard`/`branch -D`) and structured recovery commands should emit their own proof records if added.

## 9. Alternatives considered

| Option | Description | Why not (primary) |
|---|---|---|
| **A. Add a `sed`/`curl`/`python3` exemption** | Extend the `*_token` ladder | Third instance of the N-of-M workaround (CLAUDE.md signature #3). Does not close the class. Rejected. |
| **B. Widen the whitelist for all commands** | Allow `/Users/dancer/me/**` for reads and writes | Removes the write jail's protection. §4.3 read/write asymmetry gives the read benefit without the write cost — and is distinct from B because writes stay strict and reads gain a typed `Sensitive_path` deny-list (B has neither). |
| **C. Disable the path jail entirely** | Rely on sandbox containment | Correct only for Docker; Host has no container boundary (RFC-0254 §3). The jail is the only write-escape guard on Host (§4.6 M2). |
| **D. Keep the string heuristic, just fix `gh`** | One-line tweak | `gh` is already fixed (#21462, §2.2); the open class is non-gh read commands a `gh` tweak does not touch. Treats a symptom. |
| **Chosen: cwd-correct typed Path-scope + read/write split + recoverability-based floor narrow + kill-switch** | §4 | Closes the classifier class by construction; producer is compiler-checked; the kill-switch provides the missing valve with a removal obligation. |

## 10. Workaround-rejection alignment

This RFC **removes** two workaround-shaped constructs and refuses to add a third:

- The `looks_like_path_token` string classifier + per-binary `*_token` exemptions (`git`, `gh`/#21462) are the RFC-0042 substring-classifier lineage. §4.1–4.2 replace them with a closed typed producer; §9 Option A (the next exemption) is explicitly rejected per the 3-Try / workaround rule.
- #21468's floor *widening* is reverted in favor of recoverability-based narrowing (§4.5), with the explicit caveat that `find_destructive_git`'s `[@@warning -4]` suppression means the change is **not** compiler-enforced and needs a manual edit + tests (M1).
- The kill-switch (§4.6) is added as the missing valve **with a `removal target: P5` obligation and tracking issue** (CLAUDE.md Override condition), and §6 makes P3+P4 atomic so the typed fix cannot be indefinitely deferred behind the valve. It disables the only positional write-escape guard (M2) — documented, not hidden.

No telemetry-as-fix, no cap/cooldown, no new string classifier, no N-of-M exemption.

## 11. Open questions

1. **Read scope boundary + `Sensitive_path` content (§4.3).** Exactly which paths are sensitive (other keepers' `.masc/`, credential files, host secrets)? The deny-list must be typed and match **both relative and absolute** forms (the current `.masc/` guard is relative-only). This is a prerequisite, so it must be resolved during P3+P4, not deferred.
2. **`stash drop` floor membership (§4.5).** Dangling-commit recoverable via `git fsck` only — keep floored (conservative) or demote? Default: keep floored.
3. **`Path_scope.classify` caller impact (§4.4).** Confirm `exec_shell_adapter.ml`, `keeper_tool_execute_shell_ir.ml`, `bash_subset.mly` callers and `find_write_escape` behave correctly after re-parameterizing by mapped-roots.
4. **Descriptor ownership + completeness (§4.1).** Moving `command_materializes_path_arg` into `masc_exec` reverses a lib boundary; and it must gain per-slot/direction metadata it lacks today. Need a corpus-completeness test so the migration drops no command.
5. **Sandbox interaction.** On Docker (container is the boundary, RFC-0254 §5.1) should reads be even wider while writes still jail, or one policy for both profiles (as the floor chose, RFC-0254 §13 Q2)?

## 12. References

- Code anchors (worktree at `origin/main` `61481411cd`; approximate line numbers): `lib/exec_policy/exec_policy.ml` (`looks_like_path_token` ~339, `git_revisionish_token` ~356, `gh_endpointish_token` ~390, `path_argument_values` ~500, `validate_shell_ir_paths` ~631, ladder ~666-693, raw re-validate ~697), `lib/exec_policy/exec_policy_paths.ml:~51,~67-101,~103-126`, `lib/exec_policy/exec_policy_path_arg_descriptor.ml:~56-71`, `lib/exec_policy/keeper_path_check_error.ml:~18-24`, `lib/exec/capability.ml:1-7`, `lib/exec/capability_check.ml:~20-51`, `lib/exec/path_scope.ml:~1-10,~83-99`, `lib/exec/git_op.ml:~50-78`, `lib/exec/approval_policy.ml:~23-34,~43-49,~100-102`, `lib/exec/parser/bash_subset.mly:~10`, `lib/keeper/keeper_tool_execute_runtime.ml:~406,~429`, `lib/keeper_tooling/keeper_tool_execute_shell_ir.ml:~16,~120-123,~191-207`, `shell_command_gate.ml:~69-73`.
- Runtime evidence: `<base-path>/.masc/logs/system_log_2026-06-17.jsonl` (71,762 lines) — `shell_ir path_reject` WARN ×28, `Path blocked` message ×111, `policy_denied` ×0, `destructive_operation_blocked` ×79 (pre-existing deterministic guard, merge-uncorrelated). Per-day `path_reject`: 06-15 ×23, 06-16 ×11, 06-17 ×28 (the earlier "171" figure was a multi-file `rg` substring aggregate and is withdrawn).
- Parent: RFC-0208 (path policy), RFC-0254 (§10/§13 Q1/Q4/Q5). Lineage: RFC-0042 (no string classifier), RFC-0005 (typed capability substrate).
