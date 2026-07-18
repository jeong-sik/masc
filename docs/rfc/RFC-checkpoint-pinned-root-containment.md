---
rfc: "checkpoint-pinned-root-containment"
title: "Boot-pinned physical data root for checkpoint path containment"
status: Draft
created: 2026-07-18
updated: 2026-07-18
author: vincent
supersedes: []
superseded_by: []
related: ["0089", "0225", "0342"]
implementation_prs: []
---

# RFC-checkpoint-pinned-root-containment — Boot-pinned physical data root

## 0. Summary

`Keeper_checkpoint_store.canonical_session_location` rejects leaf-class
escapes (`..` / `.` / separator / NUL / leaf symlink) since PR #25137, and
`Keeper_fs ~ownership_root` rejects escapes on the durable-write chain. What
neither can detect is an **ancestor swap**: a directory between the
configured data root and the session parent replaced by a symlink, after
which `Unix.realpath parent` resolves to a physical location outside the
tree the operator configured (issue #25151, review finding on PR #25137,
issue #25077 item 1).

This RFC introduces one process-wide fact — the physical data root, resolved
once at server bootstrap while the tree is trusted — and makes the checkpoint
path boundary compare against it. No per-call root parameter is added: the
review-proposed `~expected_ownership_root` argument cannot work (§3.1).

## 1. Problem (evidence)

### 1.1 The threaded-root check is vacuous under the current API

Every caller derives the session directory as
`Filename.concat base_dir leaf`:

- `keeper_context_core_accessors.ml` `create_session`:
  `let session_dir = Filename.concat base_dir session_id`
- `keeper_run_context.ml:115`:
  `Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id)`

So the only root a caller can pass down is `base_dir`, which is exactly
`Filename.dirname session_dir` — the same value
`canonical_session_location` already canonicalizes as `parent`. A check of
the form `realpath parent ⊆ realpath root` with `root == parent` is true by
identity: if an ancestor of `base_dir` is swapped, **both sides resolve
through the same swapped link** and the check still passes. A containment
proof that cannot fail proves nothing. The existing
`Keeper_fs ~ownership_root` call sites have the same shape
(`let ownership_root = Filename.dirname session_dir` in
`keeper_checkpoint_store.ml`); they bound the chain *below* the parent,
which is real work, but say nothing about the chain *above* it.

### 1.2 What the swap can do

With write access inside the data tree, replacing an ancestor directory with
a symlink relocates every subsequent lock, checkpoint, and history write to
the link target. Issue #25077 itself scoped the practical risk: inputs are
config-derived, so the immediate exploitation path is narrow — but the
boundary claims containment it does not have, and #25137's review correctly
blocked on advertising it.

### 1.3 Why the root must be pinned at boot

Detection requires comparing against the physical location the tree had **at
a moment it was trusted**. Resolving the root freshly per call inherits the
swap (§1.1). The trusted moment the process actually has is server
bootstrap: `config.base_path` is resolved, created, and owned before any
keeper or HTTP surface can write (e.g.
`server_dashboard_http_keeper_api_post.ml:115` threads
`~base_dir:config.base_path` into every keeper API path). Boot posture is
already an established concept (RFC-0342).

## 2. Design

### 2.1 `Masc_data_root` (new, `lib/core`)

```ocaml
(* Set-once process posture. [pin] resolves the configured base path to its
   physical location and refuses a second, different pin. *)
val pin : string -> (unit, pin_error) result   (* realpath at boot *)
val pinned : unit -> string option             (* physical root, if pinned *)
val clear_for_tests : unit -> unit
```

- `pin` runs in server bootstrap immediately after `config.base_path` is
  ensured, before keeper start and before HTTP listeners accept requests.
- Unpinned process = dev/test/CLI posture. This is an explicit, logged boot
  posture (one INFO line at startup stating enforcing vs unpinned), not a
  silent permissive default: the enforcement decision is made once, at one
  observable place, by the component that owns the tree — not per call.

### 2.2 Enforcement in `canonical_session_location`

After the existing `realpath parent` (inside the same systhread block):

```ocaml
match Masc_data_root.pinned () with
| None -> ()                       (* unpinned posture: current semantics *)
| Some root ->
  if not (path_is_under ~root parent_physical)
  then raise (…typed Directory_outside_pinned_root { root; parent = … })
```

`path_is_under` is lexical on two already-physical paths (both sides are
realpath output), segment-wise, not a string prefix (`/a/bc` is not under
`/a/b`). New `directory_failure` variant, rendered by
`save_oas_error_to_string`; every lock/read/write consumer inherits the
rejection through the existing single boundary.

### 2.3 Residual (documented, not solved)

- TOCTOU between the containment check and use remains: OCaml 5.4 exposes no
  portable dirfd-relative API (already documented on `Keeper_fs`). The pin
  narrows the undetectable window to swaps racing an in-flight operation,
  which the existing "caller keeps the subtree process-owned" assumption
  covers.
- Swaps performed **before boot** are indistinguishable from legitimate
  relocation — the pin canonicalizes whatever the operator configured.

## 3. Alternatives rejected

### 3.1 Per-call `~expected_ownership_root` parameter

Vacuous under the current caller topology (§1.1) and adds a parameter every
caller can only fill with `dirname session_dir`. Rejected as
proof-by-construction theater.

### 3.2 Reject any symlink anywhere in the chain

Breaks the legitimate symlinked deployment root (`~/.masc` → mounted
volume), which is precisely why `canonical_session_location` canonicalizes
the parent at all. The pin handles this case: the deployment link is
resolved once at boot and the *physical* tree becomes the invariant.

### 3.3 `openat2`/`RESOLVE_BENEATH`

Correct kernel-level answer, not portable (Linux-only, not exposed by OCaml
5.4 stdlib / Eio 1.x on macOS targets). Revisit if the deployment surface
narrows to Linux.

## 4. Phases

1. **PR-1**: `Masc_data_root` + bootstrap pin + boot-posture log line +
   unit tests (`pin` twice with a different path fails; `clear_for_tests`).
2. **PR-2**: `canonical_session_location` enforcement + typed variant +
   tests (ancestor-symlink escape rejected when pinned; TMPDIR sessions pass
   when unpinned; symlinked-root deployment passes because both sides are
   physical).
3. **PR-3 (optional)**: `Keeper_fs` ownership-chain call sites gain the same
   upper-bound check where the pinned root is present.

## 5. Test plan

- Unit: pinned + swapped-ancestor fixture (mkdir tree, pin, replace a middle
  directory with a symlink to an outside target, assert
  `with_session_lock` returns the typed rejection and no lock file exists at
  the target).
- Unit: unpinned = today's stale-guard suite unchanged (it runs sessions in
  TMPDIR).
- Boot: assert exactly one posture log line, and that a second `pin` with a
  different path is a startup failure, not a silent repin.

## 6. Open questions

- Should `pin` failure (root unresolvable at boot) be fatal to server start?
  Proposed: yes — an unresolvable data root is not a degradable condition.
- Whether dashboard/IDE annotation stores (same `base_path` family) adopt
  the check in PR-3 or a separate RFC.
