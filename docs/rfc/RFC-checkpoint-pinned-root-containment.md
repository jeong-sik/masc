---
rfc: "checkpoint-pinned-root-containment"
title: "Immutable boot-pinned root capability for checkpoint containment"
status: Draft
created: 2026-07-18
updated: 2026-07-18
author: vincent
supersedes: []
superseded_by: []
related: ["0089", "0225", "0342"]
implementation_prs: []
---

# RFC-checkpoint-pinned-root-containment — Immutable boot-pinned root capability

## 0. Summary

`Keeper_checkpoint_store.canonical_session_location` rejects leaf-class
escapes (`..` / `.` / separator / NUL / leaf symlink) since PR #25137, and
`Keeper_fs ~ownership_root` rejects escapes on the durable-write chain. What
neither can detect is an **ancestor swap**: a directory between the
configured data root and the session parent replaced by a symlink, after
which `Unix.realpath parent` resolves to a physical location outside the
tree the operator configured (issue #25151, review finding on PR #25137,
issue #25077 item 1).

This RFC derives the physical MASC data root from the canonical base path that
`main_eio` already resolves at server bootstrap while the tree is trusted.
Bootstrap resolves `Common.masc_dir_from_base_path canonical_base_path` once,
wraps that physical `.masc` root in an immutable opaque capability, and threads
it to every checkpoint entry point. There is no process-global root, optional
enforcement mode, or test-only reset. A checkpoint call without the capability
is unrepresentable.

## 1. Problem (evidence)

### 1.1 Re-resolving the root at use time is vacuous

Every caller derives the session directory as `Filename.concat base_dir leaf`:

- `keeper_context_core_accessors.ml` `create_session`:
  `let session_dir = Filename.concat base_dir session_id`
- `keeper_run_context.ml:115`:
  `Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id)`

The invalid design is to call `realpath` on both `parent` and a root derived at
the time of each checkpoint operation. If an ancestor was swapped, both values
follow the same new link and the check succeeds by construction. The existing
`Keeper_fs ~ownership_root:(dirname session_dir)` calls still do real work
below the session parent, but do not provide the missing upper bound.

The caller topology does have a distinct root fact: `session_base_dir` is
derived from `Workspace.masc_root_dir config`, and production bootstrap has
already canonicalized `config.base_path`. The missing operation is preserving
the boot-time physical identity of the resulting `.masc` data root instead of
resolving it again later.

### 1.2 What the swap can do

With write access inside the data tree, replacing an ancestor directory with
a symlink relocates every subsequent lock, checkpoint, and history write to
the link target. Issue #25077 itself scoped the practical risk: inputs are
config-derived, so the immediate exploitation path is narrow — but the
boundary claims containment it does not have, and #25137's review correctly
blocked on advertising it.

### 1.3 Why the root must be pinned at boot

Detection requires comparing against the physical location the tree had **at
a moment it was trusted**. `bin/main_eio.ml` already computes
`canonical_base_path`, acquires the base-path lease with it, publishes it as
`MASC_BASE_PATH`, and caches the same resolved value before constructing the
server runtime. `Common.masc_dir_from_base_path canonical_base_path` is the
lexical data-root SSOT; bootstrap resolves that `.masc` path once so a
legitimate symlinked data volume is represented by its physical destination.
The checkpoint subsystem retains the result as immutable data. A second
mutable registry would create two authorities for the same fact.

## 2. Design

### 2.1 Opaque immutable root capability

```ocaml
module Checkpoint_root : sig
type t
type pin_error
type containment_error

(** Called only by bootstrap/config construction while the tree is trusted.
    Uses the Common `.masc` path SSOT and stores its exact physical destination
    plus its device/inode identity as immutable data. *)
val pin_from_base_path : canonical_base_path:string -> (t, pin_error) result

(** Verify that the pinned root still has its boot-time identity and that an
    already-canonical physical path is equal to or below it by path segment. *)
val check_descendant :
  t -> physical_path:string -> (unit, containment_error) result
end
```

- The capability is created by resolving the `.masc` path derived from the
  existing boot-canonical base path before keeper start and before HTTP
  listeners accept requests. Bootstrap must establish the data directory
  before pinning it; an absent, non-directory, or unresolvable root is a typed
  startup failure.
- Bootstrap owns the value and threads it through the keeper/session context.
  It is not stored in a module-level `Atomic`, reference, or hash table.
- Test and CLI fixtures pin their explicit temporary/configured root exactly as
  production does. Pin failure is a typed construction/startup failure.
- There is no `None`, `clear_for_tests`, permissive mode, or fallback root.

### 2.2 Enforcement in `canonical_session_location`

`canonical_session_location` takes the capability as a mandatory argument.
After the existing `realpath parent` (inside the same systhread block):

```ocaml
match Checkpoint_root.check_descendant root ~physical_path:parent_physical with
| Ok () -> Ok (Filename.concat parent_physical (Filename.basename session_dir))
| Error error -> Error (Session_directory_outside_root error)
```

The pinned root is **not** resolved again. `check_descendant` first `lstat`s the
stored physical root and compares `st_dev`/`st_ino` with the boot observation;
a missing, replaced, or wrong-kind root is a typed identity failure. It then
splits `parent_physical` into path components and compares them with the stored
physical components; `/a/bc` is not below `/a/b`. New closed
`directory_failure` variants carry root identity change and outside-root facts.
Rendering remains at the log/user boundary.

Every public checkpoint load, lock, ordinary save, and CAS save requires the
capability. The compiler therefore prevents a new call site from silently
bypassing containment. This RFC claims checkpoint containment only; extending
the same capability to unrelated durable stores requires a separate inventory
and must not be implied by this change.

### 2.3 Residual (documented, not solved)

- TOCTOU between the containment check and use remains: the
  [OCaml 5.5 Unix API](https://ocaml.org/manual/5.5/api/Unix.html) exposes no
  portable dirfd-relative API (already documented on `Keeper_fs`). The pin
  narrows the undetectable window to swaps racing an in-flight operation,
  which the existing "caller keeps the subtree process-owned" assumption
  covers.
- Swaps performed **before boot** are indistinguishable from legitimate
  relocation — the pin canonicalizes whatever the operator configured.

## 3. Alternatives rejected

### 3.1 Per-call root discovery

Calling `realpath` on a per-call `~expected_ownership_root` is vacuous (§1.1).
Passing the immutable boot-pinned capability per call is different: callers
cannot reconstruct it from `dirname session_dir`, and it never follows a later
swap. The former is rejected; the latter is the selected design.

### 3.2 Reject any symlink anywhere in the chain

Breaks the legitimate symlinked deployment root (`<base-path>/.masc` →
mounted volume), which is precisely why `canonical_session_location`
canonicalizes the parent at all. The pin handles this case: the deployment link
is resolved once at boot and the *physical* tree becomes the invariant.

### 3.3 `openat2`/`RESOLVE_BENEATH`

Correct kernel-level answer, not portable (Linux-only, not exposed by OCaml
5.5 stdlib / Eio 1.x on macOS targets). Revisit if the deployment surface
narrows to Linux.

## 4. Phases

1. **PR-1**: immutable opaque capability + construction from the existing
   boot-canonical base-path SSOT + mandatory keeper/session wiring.
2. **PR-2**: mandatory capability on every checkpoint entry point,
   `canonical_session_location` enforcement, and the closed typed rejection.
3. **PR-3**: end-to-end swap fixture proving ordinary save, load, lock, and CAS
   all reject the same escaped parent. This phase is required, not optional.

## 5. Test plan

- Unit: pinned + swapped-ancestor fixture (mkdir tree, pin, replace a middle
  directory with a symlink to an outside target, assert
  `with_session_lock` returns the typed rejection and no lock file exists at
  the target).
- Unit: every TMPDIR fixture pins its temporary base before constructing a
  session; no test can reset or omit the invariant.
- Unit: a symlinked `<base-path>/.masc` passes because the capability and
  session parent share the same boot-pinned physical data root.
- Unit: replacing the pinned physical root at the same pathname is rejected by
  device/inode identity even though lexical segment containment still holds.
- Type/build: all checkpoint entry points require the capability, so an
  unpinned caller fails compilation rather than running permissively.
- Boot: pin/canonical validation failure prevents server start with a typed
  error; no listener or keeper starts.

## 6. Closed decisions

- Pin failure is fatal to construction/startup. It is not degradable.
- This RFC owns checkpoint paths only. Dashboard, IDE annotation, and other
  stores require their own owner/inventory review before adopting the
  capability.
