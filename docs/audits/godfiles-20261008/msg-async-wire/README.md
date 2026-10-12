# Async request record and projection boundary

PR #42100. Base a592575cfd2c2c1b1382ae5685023586e44fcd5a.
Code head 1f9cffb71a65a45a5c1f1761505dc0133e70386b.

The original 3115-line owner combines immutable request states/outcomes, strict disk record/context decoding, client JSON, clock acquisition, mutable worker ownership, lane admission, persistence, cancellation and startup recovery. Private keeper_msg_async_types owns the existing canonical data (207 lines). Private keeper_msg_async_record owns pure record validation, normalization, identity predicates and JSON projection (581 lines). The root remains the worker/storage owner (2349 lines).

Public keeper_msg_async.mli is byte-identical, including the opaque durable terminal proof. Internal data sharing is registered in Dune private_modules. This source/type-check evidence does not establish installed private namespace visibility; no installation was performed.

Record/decoder/identity bodies are unchanged. The public client projection moves exactly one clock acquisition outward: root reads Time_compat.now only when completed_at is None, then supplies now to the pure projection. Completed entries supply their existing completed_at timestamp and the projection does not use now in that branch. Pending elapsed_sec remains now minus submitted_at. No cumulative timeout or gate is added. This clock boundary is source-reviewed; the existing tests below are not claimed as a deterministic injected-clock test.

Canonical type declarations and remaining root authority/effect bodies match the parent after removing the explicitly extracted blocks, moving the schema constant and adding canonical includes/imports/direct public bindings plus the clock wrapper. Wire schema, unknown/duplicate field rejection, authenticated request identity, worker locks, fork/cancellation and terminal publication retain their existing policies. No field or compatibility reader was added, and no performance improvement is claimed.

Focused command `opam exec -- dune build test/test_keeper_msg_async_durable_active_inventory.exe test/test_keeper_msg_async_terminal_event.exe` completed exit 0.
Existing inventory executable: 7 PASS, run LHSD50ZA, exit 0.
Existing terminal-event executable: 7 PASS, run 92NSTQYY, exit 0.
Both ran with --color=never. Inventory covers disk-only records, terminal residue, malformed/non-regular entries, conflicting/duplicate context, non-JSON numbers and absent partition. Terminal tests cover accepted worker identity, operator cancellation, abort observation failure, normal completion, acceptance failure, closed background switch and whole-record identity. Fixtures use isolated temporary files and in-process workers; no live Keeper/provider was contacted.

The candidate remains partially improved: lane admission, worker ownership, durable storage and recovery require further semantic audit. The entire 171-candidate campaign remains open. Results do not claim full CI, installation, deployment, live runtime, formal GitHub approval or merge.
