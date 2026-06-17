# RFC-0255: Shell-IR Path Policy — Typed Path-Scope, Read/Write Asymmetry, and Catastrophic-Floor Narrowing

**Status**: Draft
**Date**: 2026-06-18
**Builds on**: [RFC-0208](./RFC-0208-shell-ir-compositional-risk-ast.md) (Shell IR compositional risk / path policy), [RFC-0254](./RFC-0254-shell-ir-approval-autonomous-policy.md) (autonomous approval policy + catastrophic floor)
**Resolves**: RFC-0254 §13 Q1 (floor membership for local destructive git), Q4 (typed Path-scope replacement of the string path heuristic), Q5 (read/write asymmetry of the path jail)
**Related**: [RFC-0005](./RFC-0005-typed-capability-substrate.md) (typed capability substrate), [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (no-string-classifier lineage), [RFC-0088](./RFC-0088-counter-as-fix-result-propagation.md)
**Tracking**: TBD

## 1. Summary

The shell-IR path jail (`Exec_policy.validate_shell_ir_paths`) decides whether a command's path arguments stay inside the keeper workspace. It detects "which argument is a path" with a **string heuristic** — `looks_like_path_token` treats any non-URL token containing `/` as a filesystem path (`exec_policy.ml:339-343`) — and then carves out per-command exemptions one binary at a time (`git_revisionish_token`, `exec_policy.ml:354`; `gh_endpointish_token`, `exec_policy.ml:382`, added by PR #21462).

This has two measured consequences:

1. **False rejection of routine read/exploration commands.** Keeper commands such as `ls -la /Users/dancer/me/`, `cat ../../../docs/library/x.md`, `find /Users/dancer/me -maxdepth 4 …` are rejected with `Path blocked: <path> (outside allowed directories for this keeper command)` because their arguments resolve above the keeper's worktree, even though they are read-only. Live evidence (`~/me/.masc/logs/system_log_2026-06-17.jsonl`): **171 `path_reject` events** in a single day.
2. **Workaround accretion.** Each over-cut binary gets its own string exemption: `git` (`git_revisionish_token`), then `gh` (#21462). This is the N-of-M pattern CLAUDE.md's workaround bar names — the heuristic over-matches, and the fix is "exempt the next binary" (`sed`, `curl`, `python3`, … remain open). PR #21468 then *widened* the adjacent catastrophic floor (`has_short_flag` so `clean -fd`/`push -fv` Deny) — the opposite of RFC-0254 §10's "narrow the floor" prescription.

The typed substrate to fix this **already exists but is not wired**: `Path_scope.t` (`path_scope.ml:1-10`) and the `Capability.Read_path`/`Capability.Write_path` constructors (`capability.ml:1-3`). However `Capability_check.of_ir` only produces them from **redirects**, never from positional argv (`capability_check.ml:36-49`); the jail consequently consults raw `Shell_ir` strings, not capabilities.

This RFC specifies:

- **§5.1 / §5.2** Replace the string path-detection heuristic with typed `Path_scope` capabilities produced at the IR boundary and consumed by the jail. Retire `looks_like_path_token`, `git_revisionish_token`, `gh_endpointish_token`, and the per-binary exemption ladder.
- **§5.3** A read/write asymmetry: read-only commands are scoped more permissively than mutating commands (RFC-0254 §13 Q5).
- **§5.4** Reconcile the two notions of "inside workspace" (`Path_scope.classify`'s cwd-relative one vs the jail's keeper-repo-mapping + worktree-root one).
- **§5.5** Narrow the catastrophic floor to remote-irreversible git ops; demote local destructive git (worktree remove / reset --hard / clean -fd / branch -D / stash drop) to overlay-graded (RFC-0254 §13 Q1).
- **§5.6** Add a path-jail kill-switch (the jail currently has none; §2.4).

## 2. Context & problem

### 2.1 How the jail decides today (code-verified 2026-06-18)

`validate_shell_ir_paths ?keeper_id ?base_path ?workdir shell_ir` (`exec_policy.ml:631`):

1. `workdir = None` → `Ok ()` (jail disabled). Keepers always thread `~workdir = cwd` (`keeper_tool_execute_runtime.ml:429`), so this branch is never taken for a keeper.
2. `validate_simple` extracts `command_name = basename bin` and literal argv (`exec_policy.ml:711-716`). Non-literal argv (`Var`/`Concat`) skips the whole check.
3. `path_argument_values` strips flags / regex patterns / redirect operators, returning candidate positional tokens (`exec_policy.ml:500`); `command_materializes_path_arg` (`exec_policy_path_arg_descriptor.ml:56-71`) decides which commands have path-bearing positionals.
4. Per-token ladder (`exec_policy.ml:666-693`): inline `--x=path` → `is_path_flag` next-token → `git` revisionish exempt → `gh` endpointish exempt → **`looks_like_path_token` → `validate_path_value`** → else skip.
5. `validate_path_value` → `Paths.validate_path` (`exec_policy_paths.ml:103-126`); false → `Error (Path_outside_whitelist { for_keeper_command = true })`, rendered as the observed message by `Keeper_path_check_error.to_message` (`keeper_path_check_error.ml:18-24`).

### 2.2 The whitelist, and why routine reads escape it

With `workdir = Some wd`, a resolved path is allowed iff it is under `/tmp`, under the keeper's own `wd`, under the repo root above a `.worktrees/` workdir, or under a registered repo the keeper is mapped to (`exec_policy_paths.ml:116-119`). Containment is a strict prefix test (`exec_policy_paths.ml:51`). Therefore:

- `ls -la /Users/dancer/me/` — the second-brain root is the **parent** of the keeper worktree, not under it; the worktree path has the root as a prefix, not vice versa → outside.
- `cat ../../../docs/library/x.md` — `resolve_path` normalizes `../` against `wd` (`exec_policy_paths.ml:16-19,40-47`), landing above the repo root → outside.
- `find /Users/dancer/me …` — `find` is path-materializing; the absolute root is outside.
- `gh api /repos/owner/repo/check-runs` — leading-`/` endpoint matches `looks_like_path_token`. PR #21462 added `gh_endpointish_token` (`exec_policy.ml:382`) specifically to exempt it; from source the leading-`/` form **is** exempted (token contains `/`, no `..`, does not resolve to an existing file). The 2026-06-17 14:xx UTC `gh` rejections predate the current server process (`ELAPSED ≈ 18 min` at observation, vs log timestamps hours earlier), so they are attributed to a pre-#21462 instance. `gh` is thus the *first* N-of-M exemption, not an open defect.

### 2.3 The string heuristic is a classifier the compiler cannot check

`looks_like_path_token` is exactly the substring-classifier shape RFC-0042 closes elsewhere: "is this argument a path?" is answered by `String.contains token '/'`, with hand-maintained per-binary exceptions. A new binary whose arguments contain `/` but are not paths (a `sed` address `/^foo/d`, a scheme-less `curl host/path`, a `python3 -c 'a/b'` fragment, an `npm` scoped package `@scope/pkg`) is misclassified until someone adds the next `*_token` exemption. There is no closed type forcing every such case to be considered.

### 2.4 The jail has no kill-switch

`MASC_SHELL_IR_APPROVAL_GATE_ENABLED` (default `true`, `env_config_runtime.ml:948-955`) toggles only the *approval* gate. **Both** branches of `keeper_tool_execute_runtime.ml:406` call `dispatch_classified`, which unconditionally runs `validate_paths` (`keeper_tool_execute_shell_ir.ml:120-123`; the approval branch delegates to the same on Allow, `:197-207`). A search for an independent flag found none. The only source-level disable is the `workdir = None` branch, which keepers never hit. **`path_reject` cannot be disabled without a rebuild** — there is no operational mitigation for a path-jail false-positive storm. This is the gap that turned the merge into a hard stall with no env-level escape hatch.

### 2.5 Read = write today

`command_materializes_path_arg` lumps read-only `cat`/`ls`/`find`/`grep`/`head`/`tail`/`rg`/`sed`/`stat`/`tree`/`wc` into the same set as mutating commands (`exec_policy_path_arg_descriptor.ml:56-60`), and all candidate tokens take the same `validate_path_value ~requires_existing_dir:false` against the same whitelist (`exec_policy.ml:689-690`). A keeper reading a sibling doc and a keeper writing outside the workspace are treated identically. RFC-0254 §13 Q5 flagged this asymmetry as unresolved; it is the reason read-only exploration is as jailed as mutation.

### 2.6 The catastrophic floor over-includes local destructive git

`catastrophic_floor` Denies any `Git_op.Destructive` regardless of overlay (`approval_policy.ml:100-102`). `git_op.ml:50-77` classifies `branch -D`, `stash drop`, `push --force/-f`, `reset --hard`, `clean -f`, `worktree remove` as Destructive. Of these, only `push --force`/`push --delete` are **remote-irreversible**; the rest are local and routine for keepers managing worktrees. Measured `policy_denied` from this floor is currently 0 (the floor has not yet bitten in the observed window), but #21468 widened it, increasing the probability that routine worktree teardown will Deny. RFC-0254 §10's last paragraph prescribes narrowing the floor to remote-irreversible ops; §13 Q1 left it open. (Note: `destructive_operation_blocked` in the logs is a *different*, pre-existing deterministic guard in `keeper_tool_deterministic_error.ml`, ~70-100/day with no merge-correlated change — out of scope here.)

## 3. Design principle

Parse, don't validate (Alexis King) + Simple Made Easy (Hickey): the question "is argument *i* a path, and is it a read or a write?" must be answered **once**, at the IR boundary, by a total function that produces a typed `Path_scope` capability — not re-derived from strings at the policy layer with a growing exemption list. The jail then consumes typed capabilities and never sees a raw token. A new binary cannot silently bypass classification because the producer's command descriptor is the single closed source of "what is path-bearing", checked by the compiler at every call site.

## 4. Design

### 4.1 Typed path-capability production (resolves §13 Q4, producer half)

Extend `Capability_check` so that `of_ir`/`head_cap` emits `Read_path`/`Write_path` capabilities for the **positional path arguments** of path-materializing commands, not only for redirects (`capability_check.ml:36-49` today). The per-command knowledge currently in `exec_policy_path_arg_descriptor.ml` (which positional slots are paths; which flags take a path value; read vs write intent) moves into — or is consumed by — the producer.

- Each path argument becomes `Read_path scope` or `Write_path (scope, mode)` where `scope : Path_scope.t` carries the resolved+classified path.
- Tokens that are *not* paths (a `gh` API endpoint, a `sed` address, a regex, a scoped npm package, a scheme-less URL) are simply **not emitted as path capabilities** — they never reach the jail. This is what retires the `*_token` exemption ladder: non-paths are excluded by *construction*, not by a denylist of exceptions.

### 4.2 Jail consumes typed scopes (resolves §13 Q4, consumer half)

`validate_shell_ir_paths` is rewritten to fold over the command's `Path_scope` capabilities instead of re-scanning argv strings. Removed: `looks_like_path_token` (`exec_policy.ml:339`), `git_revisionish_token` (`:354`), `gh_endpointish_token` (`:382`), and the string ladder in `validate_path_values` (`:666-693`). `Paths.validate_path` consumes a `Path_scope.t` whose `scope` field is already classified, rather than a raw string.

### 4.3 Read/write asymmetry (resolves §13 Q5)

The jail decision becomes a function of capability *kind*:

- `Write_path (scope, _)` — must be inside the keeper workspace (the current whitelist). A write that escapes is `Deny`/`Path_reject` (unchanged strictness for mutation).
- `Read_path scope` — permitted over a **wider** boundary. The exact boundary is an open question (§7), but the intent is: read-only access to the second-brain tree / parent docs / registered repos a keeper is mapped to is allowed; only genuinely sensitive reads (credentials, other keepers' private state) are denied. A read is never irreversible, so the threat model differs from a write.

This directly unblocks `ls`, `cat`, `find`, `grep`, `head`, `tail`, `rg`, `wc`, `stat`, `tree` over the workspace's parent docs — the dominant false-positive class in §2.2.

### 4.4 One notion of "inside workspace" (§13 Q4 reconciliation)

`Path_scope.classify` (`path_scope.ml:83-99`) classifies relative to `cwd` and does not know the jail's keeper-repo-mapping + `.worktrees/` repo-root rule (`exec_policy_paths.ml:67-101`). These two definitions of `Inside_workspace` must be unified into one source of truth, used by both the producer's classification and the jail's whitelist. The keeper-repo-mapping rule is the authoritative one (it encodes which repos a keeper may touch); `Path_scope.classify` is extended to take the keeper's mapped roots rather than bare `cwd`.

### 4.5 Catastrophic-floor narrowing (resolves §13 Q1)

Split `Git_op.Destructive` into:

- **remote-irreversible** — `push --force`, `push --delete` (and force-with-lease variants). These stay in the trust-independent `catastrophic_floor`.
- **local-destructive** — `reset --hard`, `clean -f[d]`, `branch -D`, `stash drop`, `worktree remove`. These are demoted to an overlay-graded risk (Mutating-equivalent), so under the autonomous overlay (`Observe`) they `Allow`, and under an operator overlay they could `Ask`. Local destructive ops are recoverable (reflog, re-clone) and are routine keeper lifecycle.

The split is a type change in `git_op.ml`, so the compiler forces every match site to handle both arms — no `_ ->` catch-all (CLAUDE.md FSM rule). This also reverts the direction of #21468 (which widened the floor) in favor of RFC-0254 §10's narrowing.

### 4.6 Path-jail kill-switch (closes §2.4)

Introduce `MASC_SHELL_IR_PATH_JAIL_ENABLED` (default `true`, lifecycle `Active`, re-readable per process) registered in `Feature_flag_registry`, gating `validate_shell_ir_paths` so a path-policy false-positive can be disabled without a rebuild — symmetric with the approval-gate kill-switch RFC-0254 §10 relies on. This is a **safety valve, not the fix**: the fix is §4.1-4.4; the flag exists so the next regression is an env toggle + restart, not a stall with no escape.

## 5. Non-goals

- **Network-egress / exfiltration containment** — unchanged from RFC-0254 §6; the path jail is about filesystem scope, not network. `curl host/path` is excluded from path classification (it is not a path), but network containment remains the sandbox's job.
- **Replacing the keeper-repo-mapping authorization model** — §4.4 unifies the *classification*, not the *authorization* of which repos a keeper may touch.
- **Removing the approval floor** — RFC-0254's floor stays; this RFC only narrows its git membership (§4.5) and fixes the orthogonal path layer.

## 6. Implementation plan

1. **P1 — kill-switch (§4.6).** Smallest, highest-leverage, unblocks operations immediately. `MASC_SHELL_IR_PATH_JAIL_ENABLED` flag + gate in `validate_shell_ir_paths`. Ship first so a regression has an env-level mitigation.
2. **P2 — floor narrowing (§4.5).** Type-split `Git_op.Destructive`; move local-destructive to overlay-graded; tests invert (#21468's widened cases for local ops become `Allow` under autonomous; `push --force` stays `Deny`). Self-contained in `lib/exec`.
3. **P3 — typed path producer (§4.1).** Extend `Capability_check.of_ir` to emit `Read_path`/`Write_path` for positional argv; fold the descriptor corpus in.
4. **P4 — jail consumes typed scopes + read/write asymmetry (§4.2-4.3).** Rewrite `validate_shell_ir_paths`; delete `looks_like_path_token`/`*_token`; widen read scope. Retire the `git`/`gh` exemptions (and never add a `sed`/`curl` one — that would be the rejected N-of-M PR).
5. **P5 — workspace classification unification (§4.4).** Single `Inside_workspace` definition shared by producer and jail.
6. **P6 — verification (§7).**

P1+P2 are independently shippable and resolve the *floor* and the *operational gap* quickly; P3-P5 are the structural root fix for the *path heuristic* and should land as one coherent change (a half-migrated state would mean two classifiers running — the duplicate-classification anti-pattern RFC-0254 §5.4 warns against).

## 7. Verification

- **Property test:** for the corpus of routine keeper read commands (`ls`/`cat`/`find`/`grep`/`gh api`/`git -C`) over workspace-parent and registered-repo paths → no `Path_reject`. For writes escaping the workspace → `Path_reject`. For `push --force` → floor `Deny`; for `reset --hard`/`worktree remove` under autonomous → `Allow`.
- **TLA+ bug-model** (repo spec-mutation pattern, per RFC-0254 §9): model the jail as read/write × inside/outside; `BugAction` = an out-of-workspace **write** reaching `Allow`; `SafetyInvariant` `WriteEscapeNeverAllowed`. Clean spec passes; `-buggy.cfg` violates. A second invariant `ReadInsideWorkspaceNeverDenied` guards against re-introducing the over-cut.
- **No-duplicate-classifier check:** assert (test or grep-gate) that after P4 `looks_like_path_token` and the `*_token` exemptions are *deleted*, not merely bypassed — so the string classifier cannot silently return.
- **Build:** `DUNE_CACHE=disabled dune build --root .` in the worktree (the `lib/exec`/`lib/exec_policy`/`lib/keeper` boundary has produced stale-cmx cross-lib link issues before; full cache-disabled build required, not just `@check`).

## 8. Rollout

- P1 kill-switch ships first; if the live false-positive storm recurs, `MASC_SHELL_IR_PATH_JAIL_ENABLED=false` + restart is the immediate mitigation (the env is read at process start, so a restart is required — there is no live flip).
- P3-P5 graduate behind the same flag: land with the flag honored, soak, then make typed-scope the only path.
- Post-enable verification (`~/me/.masc/logs/system_log_*.jsonl`): `rg 'path_reject'` should drop to genuine write-escapes only; `rg 'policy_denied'` should show only remote-irreversible git.

## 9. Alternatives considered

| Option | Description | Why not (primary) |
|---|---|---|
| **A. Add a `sed`/`curl`/`python3` exemption** | Extend the `*_token` ladder for the next over-cut binary | The third instance of the N-of-M workaround (CLAUDE.md bar, signature #3). Does not close the class. Explicitly rejected. |
| **B. Widen the whitelist to the second-brain root for all commands** | Allow `/Users/dancer/me/**` for reads and writes | Removes the write jail's protection (a write-escape to a sibling repo would pass). Read/write asymmetry (§4.3) gives the read benefit without the write cost. |
| **C. Disable the path jail entirely** | Rely on sandbox containment | Correct only for Docker; the Host/Local profile has no container boundary (RFC-0254 §3). The jail is the only write-escape guard on Host. |
| **D. Keep the string heuristic, just fix `gh`** | One-line tweak | `gh` is already fixed (#21462, §2.2); the open class is the non-gh read commands, which a `gh` tweak does not touch. Treats a symptom. |
| **Chosen: typed Path-scope + read/write split + floor narrow + kill-switch** | §4 | Closes the classifier class by construction; the compiler enforces completeness; the kill-switch provides the missing operational valve. |

## 10. Workaround-rejection alignment

This RFC **removes** two workaround-shaped constructs and refuses to add a third:

- The `looks_like_path_token` string classifier + per-binary `*_token` exemptions (`git`, `gh`/#21462) are the RFC-0042 substring-classifier lineage. §4.1-4.2 replace them with a closed typed producer; §9 Option A (the next exemption) is explicitly rejected per the 3-Try / workaround rule.
- #21468's floor *widening* (`has_short_flag`) is reverted in favor of RFC-0254 §10's narrowing (§4.5), with a type-split that the compiler checks (no `_ ->` catch-all).
- The kill-switch (§4.6) is added as the missing safety valve, not as a fix; the fix is the typed substrate.

No telemetry-as-fix, no cap/cooldown, no new string classifier, no N-of-M exemption.

## 11. Open questions

1. **Read scope boundary (§4.3).** Exactly how wide is "read-only allowed"? Whole second-brain tree? Only registered repos + their parents? Must exclude credential files and other keepers' private state — what is the deny-list for reads, and is it typed (e.g. a `Sensitive_path` scope variant) rather than string-matched?
2. **Workspace-classification authority (§4.4).** Confirm keeper-repo-mapping is the single source of truth and that `Path_scope.classify` should be parameterized by mapped roots; does any non-keeper caller of `Path_scope.classify` rely on the cwd-relative behavior?
3. **Floor split granularity (§4.5).** Is `branch -D` of a *remote-tracking* branch or `push --delete` the only remote-irreversible branch op? Should `git update-ref -d` / `git reflog expire --expire=now` join the remote-irreversible floor?
4. **Sandbox interaction.** On Docker, should the read scope be even wider (container is the boundary, RFC-0254 §5.1) while writes still jail? Or keep one policy for both profiles (RFC-0254 §13 Q2 chose one policy for the floor)?
5. **`command_materializes_path_arg` corpus migration.** Moving it into the producer must preserve the existing per-command knowledge (which `find`/`sed`/`tar` flags take paths) — is there a corpus completeness test, or could the migration drop a command?

## 12. References

- Code anchors (worktree at `origin/main` 61481411cd): `lib/exec_policy/exec_policy.ml:339,354,382,500,631,656-693,711-716`, `lib/exec_policy/exec_policy_paths.ml:51,67-101,103-126`, `lib/exec_policy/exec_policy_path_arg_descriptor.ml:56-71`, `lib/exec_policy/keeper_path_check_error.ml:18-24`, `lib/exec/capability.ml:1-3`, `lib/exec/capability_check.ml:36-49`, `lib/exec/path_scope.ml:1-10,83-99`, `lib/exec/git_op.ml:50-77`, `lib/exec/approval_policy.ml:100-102`, `lib/keeper/keeper_tool_execute_runtime.ml:406,429`, `lib/keeper_tooling/keeper_tool_execute_shell_ir.ml:120-123,197-207`, `lib/config/env_config_runtime.ml:948-955`.
- Runtime evidence: `~/me/.masc/logs/system_log_2026-06-17.jsonl` — `path_reject` ×171 (`gh api /repos/...`, `ls /Users/dancer/me/`, `cat ../../../docs/...`, `find /Users/dancer/me`), `policy_denied` ×0, `destructive_operation_blocked` ×79 (pre-existing deterministic guard, merge-uncorrelated).
- Parent: RFC-0208 (path policy), RFC-0254 (§10/§13 Q1/Q4/Q5). Lineage: RFC-0042 (no string classifier), RFC-0005 (typed capability substrate).
