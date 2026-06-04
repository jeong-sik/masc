---
rfc: "0210"
title: "Keeper Playground Repo Currency (fetch + fast-forward, work-preserving)"
status: Draft
created: 2026-06-02
updated: 2026-06-02
author: yousleepwhen
supersedes: []
superseded_by: null
related: ["0070", "0104"]
implementation_prs: []
---

# RFC-0210: Keeper Playground Repo Currency

## Problem

Local-profile keepers (14/16) do code work in a git working copy at
`.masc/playground/<keeper>/repos/<repo>`. These working copies are
provisioned once and **never advanced to current `main`**, so keepers
build/edit/test against stale trees (observed: 433 commits behind on the
fleet; a keeper turning on a tree that predates the cascade demolition +
runtime renames produces incoherent state — e.g. `D config/cascade.toml`
in the working tree).

Three code-level facts (verified 2026-06-02) cause this:

1. **No advance capability.** `lib/repo_manager/repo_git.ml` exposes only
   `clone` / `fetch` / `get_branches` / `get_origin_url` /
   `get_recent_commits`. There is **no** `merge` / `fast-forward` / `pull`
   / `reset` / `checkout`. So even a fetch cannot move a working tree.

2. **Staleness is masked.** `Playground_repo_readiness.inspect` measures
   currency off `@{upstream}` (`playground_repo_readiness.ml:186-205`). The
   playground repos were created by `git fetch <local-origin> + git
   checkout -b main FETCH_HEAD`, which sets **no upstream**. With upstream
   unset, `ahead/behind = None`, and the state resolves to `"ready"`
   (`:222-226`). A stale repo therefore reports healthy.

3. **No sync trigger.** The only periodic repo job (`repo_sync` fiber in
   `server_bootstrap_maintenance.ml`) is fetch-only and operates on the
   **different** `.masc/repos/<id>` lane, with `auto_sync` gating;
   `clone_sandbox_repo` hardcodes `auto_sync=false`. The turn-start gate
   (`agent_tool_execute_path.validate_repo_path_ready`) calls
   `ensure_ready` only when the toplevel probe fails, and `ensure_ready`
   handles only `missing_clone`/`not_git_repo` (reclone); for
   `behind_upstream`/`dirty` it returns a prose hand-off telling the
   keeper LLM to fix it by hand.

## Scope

In scope: make the keeper's working copy **current with `main`** before it
does code work, **without destroying uncommitted or unpushed work**.

Out of scope (recorded as separate issues, NOT fixed here):

- **Stranded output.** There is no automatic commit/push/PR; keeper work
  reaches `origin` only if the keeper LLM pushes. Returning work to main is
  a larger lifecycle problem — separate issue.
- **Feature-branch currency.** A fast-forward only helps a keeper sitting
  on `main`. Keepers on self-made task branches (e.g. `task-575-*`) are
  *detected and surfaced* as stale, but not auto-advanced (auto-rebasing a
  divergent branch is a conflict/destruction risk). The proper fix is to
  cut new task branches from fresh `origin/main` at task start — deferred
  to the keeper task-lifecycle work.

## Design

### D1. Read-only detection off an explicit ref (un-mask)

`inspect` keeps measuring `ahead/behind` against `@{upstream}` for the
existing fields, and **additionally** measures currency against
`origin/<default_branch>` explicitly (default `main`). New read-only
fields: `behind_default : int option`, `current : bool`. A repo with no
upstream is no longer silently `"ready"` when it is behind
`origin/<default_branch>`.

`inspect` stays read-only (no fetch). True currency requires a fetch, which
belongs to the advance step (D2), not the probe.

### D2. Work-preserving advance (`ensure_current`)

A new `ensure_current ~config ~meta ~repo_name ()` runs at turn-start
(before code work). Algorithm:

1. `git fetch origin <default_branch>` (local origin; cred used if mapped).
2. Re-evaluate the working branch:
   - **clean working tree, on `<default_branch>`, and HEAD is an ancestor
     of `origin/<default_branch>`** (i.e. fast-forwardable, no local
     divergence) → `Repo_git.fast_forward` to `origin/<default_branch>`.
   - **anything else** (dirty / not on default branch / diverged / ahead /
     detached HEAD) → **do not touch the tree**; return a typed
     `Stale_preserved` outcome carrying the reason, so the caller surfaces
     it. Work is preserved by construction.

`ensure_current` never runs `reset --hard`, `pull`, `rebase`, `clean`, or
`rm`. The only mutation is `fetch` (ref-only) and `merge --ff-only` (which
git refuses if it would not be a pure fast-forward).

### D3. `Repo_git.fast_forward` (new, ff-only)

```
val fast_forward :
  repository:repository -> target_ref:string ->
  (unit, string) result
```

Runs `git merge --ff-only <target_ref>` via `Masc_exec.Exec_gate` (same
gating as every other repo-manager git call). `--ff-only` makes
non-destructiveness a property git enforces: it errors rather than create a
merge commit or rewrite history.

### D4. Quarantine instead of `rm -rf` on corrupt repos

`ensure_ready`'s `not_git_repo` branch currently `rm -rf`s the clone before
recloning (`playground_repo_readiness.ml:311-320`) with no stash/commit first —
if a dirty clone trips the `not_git_repo` classifier, uncommitted work is
destroyed. Replace `rm -rf <path>` with `mv <path>
<path>.corrupt-<turn-id>` (quarantine) so any salvageable work survives a
reclone. Quarantine dirs are swept by existing disk-hygiene.

## Work-preservation policy (the load-bearing decision)

The default policy is **conservative**: auto-advance only the unambiguously
safe case (clean tree, on the default branch, pure fast-forward). Every
other state is preserved untouched and surfaced. This never destroys
uncommitted or unpushed work and never resolves a conflict silently.

A more aggressive policy (e.g. `stash --include-untracked` a dirty default
branch, fast-forward, then re-apply the stash) is possible but deferred: it
moves keeper state under the keeper's feet mid-stream and is only worth it
if the conservative default proves insufficient. The knob is named here so
the choice is explicit, not implicit.

Rejected: adding `pull` / `reset --hard` / `rebase` to advance trees
unconditionally. That is a destructive shortcut (CLAUDE.md workaround bar)
and would silently discard the unpushed work the fleet currently holds
(nick0cave ahead=1, ramarama ahead=4, umberto ahead=5, qa-king detached
ahead=435).

## Validation

- `inspect` reports `current=false` / `behind_default>0` for a no-upstream
  repo behind `origin/main` (un-mask regression).
- `ensure_current` fast-forwards a clean default-branch clone and leaves
  `head` at `origin/main`.
- `ensure_current` leaves a **dirty** clone untouched and returns
  `Stale_preserved` (no file lost).
- `ensure_current` leaves a **diverged/ahead** clone untouched (no commit
  lost).
- `ensure_current` leaves a **feature-branch / detached HEAD** clone
  untouched.
- `fast_forward` errors (does not merge-commit) when the target is not a
  fast-forward.
- corrupt-repo repair quarantines (moves) rather than `rm -rf`s.

## Operational note

The existing live playground repos cannot be batch-refreshed while keepers
are actively turning (verified active: 14 turn_started / 3 min) — stashing
or fast-forwarding under a mid-turn keeper's cwd risks corrupting its
in-flight Execute. Once D2 ships, each keeper self-refreshes safely at its
own turn boundary, so no risky fleet-wide manual operation is needed. A
manual refresh, if wanted before D2 ships, requires quiescing the fleet
first.

## RFC-gate note

The primary fix site `lib/playground_repo_readiness.ml` is **not** in the
CLAUDE.md `agent_delegation` literal prefix list, though it is the host-path
repo lifecycle owner. The fix also touches `lib/repo_manager/repo_git.ml`
(gated). Recommend widening the `agent_delegation` prefix list to include
`lib/playground_repo_readiness*` and `lib/keeper/keeper_sandbox*`.
