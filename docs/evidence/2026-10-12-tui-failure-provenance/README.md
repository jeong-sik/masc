# Failure provenance source authority

Base: c1280695093e4e1e0aded2b66c5c5aa21a2c1361.

The request_failure history branch read raw delivery-key fields and supplied
Operation ownership even when the canonical codec rejected the key or the slot
was missing/wrong. The current producer append_request_failure_once delegates to
append_terminal_message_once, persisting the canonical Terminal_result slot.
History now requires valid terminal provenance before granting execution source,
operation lookup, failure origin or turn ownership. Failure content is preserved
when provenance is unowned; there is no content-pattern fallback.

Artifacts: /tmp/masc-tui-failure-provenance-20261012/.
The parent harness copies the old raw origin expression. The current harness
runs the new production failure source helper and the source-to-origin arms.
Both use the full real delivery codec and real Turn_ref module with minimal
checkpoint/trace-id/execution-id surroundings. Parent exits 1: invalid failure
acquired authority. Current exits 0 for canonical terminal ownership and refusal
of absent/wrong slot, duplicate key fields, invalid ID and unknown key fields.
Whole row construction, failure body preservation and history ingestion are not
executed by this isolated harness.

The canonical producer fixture was corrected to include Terminal_result; new
registered state fixture covers original body retention and absent ownership.
Fixtures are unexecuted. Two changed OCaml files passed syntax-only parsing and
diff whitespace checking. Full typecheck/build, runtime, UI/screenshots, CI,
formal approval and merge are unverified.
