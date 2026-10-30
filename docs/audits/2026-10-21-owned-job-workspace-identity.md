# Owned-job physical workspace identity

This is a source implementation audit. No behavior, elapsed time, build, typing,
warning, link, runtime or TUI acceptance is claimed.

## Problem and source boundaries

Prepared Composition journals resolve their explicit base path with `realpath`.
Their result selection and fresh owned-job readiness use that physical root.
Owned-job Store and Invocation previously used absolute lexical normalization;
backend preparation compared the same lexical configuration spelling. A real
workspace below a parent-directory alias could pass existing no-follow directory
checks while retaining a different root string. Its result hint could miss the
physical journal key, and the journal's fresh `Store.load` could reject that
same owner's root. This is a source-confirmed path, not an executed production
reproduction. Complete maintenance does not repair incompatible owner strings.

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Parent-directory alias | May be persisted as a distinct root spelling | Resolve existing physical root before deriving job paths |
| Original invocation | Binding uses lexical root | Store resolver supplies the same physical root |
| Prepared backend | Lexical config/spec agreement | Physical config/spec agreement before backend preparation |
| Durable owner and result hint | Original lexical root may differ from journal | New owner/spec/hint share journal's physical workspace |
| Fresh result read | Physical root can disagree with stored alias | Same immutable owner through physical or parent-alias input |
| Root-leaf symlink | Backend directory validation refuses | Resolver also refuses before granting root identity |
| Missing/unreadable root | No authority | Explicit Missing/I/O refusal; no lexical fallback |
| Later effects | Frozen original owner, daemon and directories | Same checks, with physical root revalidation |

The common owned-job resolver lives beside backend authority and is used by
Store, including the existing Invocation and Runtime callers. It captures the
normalized absolute input on the caller, then performs root `lstat` and
`realpath` through `Eio_guard.run_in_systhread`; outside Eio it runs inline.
Typed root errors distinguish invalid input, absent root, non-directory root
and host I/O failure. Store preserves Missing, Invalid_authority and Io_failed
categories. Cancellation propagates. Generic `Config_dir_resolver` and
`Workspace_root` retain their existing lexical/nonexistent-root contracts.

Name resolution is not an atomic filesystem transaction or effect permission.
After binding a root, existing private-path, UID/permission, unique-link,
no-follow, directory device/inode, saved daemon/container/image/argv/mount,
source/input/output, intent/CAS, completion and cleanup validation remain.
Retargeting an alias cannot rebind an already frozen physical specification.
The caller's original configuration/observation path is not rewritten. No new
candidate/result cache, timer, cap, retry or runtime permission is introduced.

Already persisted journals/preparations with a nonphysical base spelling are
not migrated or relabelled. They remain retained and refuse incompatible reads;
no replacement job or relaunch is authorized. Existing canonical records retain
their format and receipt. This source change does not claim automatic recovery
of historical alias owners or install the new code in a running server.

## Authored resource cases (all unexecuted)

The existing persisted synthetic Docker protocol and actual public Keeper
handlers gain two resource cases and one child/parent variant:

1. Start via a parent alias with an immutable input, restart transport and replay
   the original invocation, collect status, retrieve the original job result
   after a different Task, and read both complete output blobs. The owner,
   preparation and real bind mount agree on the physical workspace; physical and
   alias Store load/recovery retain the same source, inputs and committed owner.
2. Copy the actual owner bytes to another workspace, retarget the configuration's
   parent alias there, and refuse both copied-owner reads and preparation of the
   saved original specification. Refuse a root-leaf symlink and preserve Missing
   for a nonexistent root. Keep both owner files unchanged and inspect the exact
   original still-running backend resource under its frozen authority.
3. Start the original job through a parent alias in the existing two-job,
   original Named-child/prepared-parent scenario. The real producer's owner hint
   must match the physical journal before selected readiness, automatic child
   and parent continuation, original stdout, unrelated owner bytes and independent
   queue work checks. No manual parent hint or maintenance pulse is added.

The fixture retains the requested alias for bundle configuration while exposing
its physical root for independent resource assertions. Existing variants keep
their original configuration and resource paths. These cases are neither helper
invocation counts nor UI wording/layout/snapshot/PTY tests. Synthetic CLI receipts
do not prove actual Docker isolation, physical overlap or live server behavior.

## Costs and Before/After limits

Each resolver call now adds one successful-path host `lstat` and `realpath`,
worker dispatch in Eio, and a typed error/result. Existing public operations can call the resolver repeatedly during preparation;
backend directory checks also resolve their saved root. Historical journal rows
keep lexical structural validation and the final owner is matched against the
physical operation scope. They do not each add a root filesystem lookup. This is a correctness repair, with added preparation
and read cost, not a default-path speedup claim. Symlink traversal, filesystem
failure and cancellation cost remain unmeasured. There is no root cache.

Store's remaining journal/path/CAS code and backend snapshot, codec, process,
receipt and effect bodies retain their original source. New resolution does not
remove filesystem validation or add I/O to the durable hint callback itself.
The existing alias fixture option performs no alias filesystem operations when
not selected, but retains an additional configured-root string in the fixture.

Five changed OCaml files are checked by parsing only, interfaces first. This
cannot establish types, warnings, linking or behavior. Resource cases are only
authored. No tests/build/CI/native/model/controller/PTY execution, installation,
restart or live writes. Whole-stack current-head independent approval, actual
cold usable input/TUI observation and all six original goal axes remain pending.
Matched actual Before/After must retain failed, cancelled, interrupted,
not-started and unfinished observations; no measured cohort or speedup exists.
