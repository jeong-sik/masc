# Admission discovery consumes one execution observation

The consumer patch changes three files. [caller-proof.json](caller-proof.json)
binds their exact final source bytes and parser receipts. The Owner primitive
and complete Store/Owner native fixture are documented in [README.md](README.md).

`keeper_librarian_admission_parts.ml` retains the original validation order:

1. Confirm the current owner; load and decode all parts, then all partitions.
2. Validate forest structure and every partition's execution proof.
3. Read the execution scope, restore each capture and reject duplicate parents.
4. Validate historical root replacements, including their existing Current
   receipt observations and possible publication reconciliation.
5. Return the inventory.

A private projection supplies the execution read at step 3. Ordinary `discover`
and the prospective `retain_root` forest check use the ordinary `load_scope`
projection returning `(records, ())`; they do not allocate an observation map.
The fixed `discover_observing_executions` entrypoint instead obtains
`Owner.observe_scope`. Its opaque observation is returned separately from the
unchanged inventory. It retains the first canonical ASTs through step 4; the
native fixture explicitly reports that historical-gap cost using a synthetic
overlapping-work root, rather than pretending to execute those historical
proofs.

`keeper_librarian_admission_owner.ml` consumes that observation immediately with
`Owner.reread_scope` in the same `discover` invocation. This replaces only the
second execution `load_scope`. Capture restoration, Commit validation,
duplicate-parent rejection, gate discovery and gate-chain validation still
follow the fresh reread in their original order. Immutable binding, body SHA
and current progress semantics belong to the Owner primitive, not the Parts
projection. No Store body writer changes.

The observation never enters a Parts inventory, Admission inventory or `held`
state. The separate `run_queue` discoveries around partition/gate recovery
therefore create and consume separate observations. Existing
`Read_after_last_write`/`Written_since_read` decisions are unchanged. This does
not suppress existing Current reconciliation during one validation or carry a
hint across the separate recovery stages.

Whole actual Owner MLI/ML typing and the 83-assertion native fixture passed.
All three final consumer files parsed. Actual wrapped Parts MLI typing stopped
on the existing Capture CMI's incompatible assumptions about the newly compiled
Owner interface. That attempt preceded the final documentation-only Parts MLI
clarification; both hashes and the exact error are retained in the caller proof.
No interface shim, substitute consumer implementation, dependency rebuild,
Dune build or MASC integration execution was used to turn that blocker into a
pass. Independent source review is a separate evidence layer.
