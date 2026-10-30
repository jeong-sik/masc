# Memory OS pure support boundary

PR #42098. Base 183b9fe18a1736c2b1af9faa9440f04a0c94b5cb.
Code head 69aa513a8210c526e82eb8cb8d279b5c29eeb2c9.

The original current-memory owner mixes support-graph maintenance, fact re-observation, snapshot calculation, strict snapshot decoding, locks, receipts, journals and recovery. Private keeper_memory_os_current_types owns the canonical existing immutable data declarations. Private keeper_memory_os_support_core owns support closure, invalidation, fact delta, basis merge, pure snapshot construction and upsert calculation. The storage owner keeps clock acquisition, locking, filesystem reads/writes, durable range/retraction receipts, quarantine, journal reconciliation and commit observation.

The strict root decoder uses the same core identity map, payload comparison and support graph as write-side snapshot calculation. Support closure uses locally allocated worklist/maps; no filesystem, clock acquisition, logging, provider or process-wide mutable state was added to the core. The existing now parameter is an admitted timestamp supplied by the storage boundary, not an elapsed-time gate.

Root 3300 -> 2868 lines; canonical data 127 ML lines; pure core 310 ML lines. Public keeper_memory_os_current.mli is byte-identical. All extracted calculation function bodies and remaining root body match the parent after removing exactly the extracted blocks and adding canonical includes/imports plus the direct public merge_basis binding. The moved data declarations are unchanged; only an obsolete schema-compat history comment was removed, and final newlines were normalized. No compatibility reader, product field, performance claim or new public test API was added.

Focused build `opam exec -- dune build test/test_keeper_memory_os_current.exe` completed exit 0.
Existing executable `_build/default/test/test_keeper_memory_os_current.exe --color=never` completed exit 0: 90 PASS, run 8MT982TY. It covers alternate support paths, reverse-ordered closure, cascade retraction, unsupported upsert rejection, exact snapshot/CAS, provenance and insertion-time re-observation, durable range receipts, torn journal recovery, quarantine and commit cancellation/observation. Filesystem fixtures use temporary keeper directories; no live Keeper or provider was contacted.

Source review and focused consumer execution are distinct from full CI, installation, deployment, live runtime, formal GitHub approval or merge. The baseline candidate remains partially improved: its snapshot codec, durable receipt/journal recovery and persistence responsibilities still require semantic audit. The full 171-candidate campaign remains open.
