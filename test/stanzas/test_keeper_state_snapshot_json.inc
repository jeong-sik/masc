; RFC-MASC-001 Phase 1: structured working_context in Checkpoint.
; Round-trip, envelope, patch_checkpoint, dual-source read.

(test
 (name test_keeper_state_snapshot_json)
 (modules test_keeper_state_snapshot_json)
 (libraries masc_test_deps))
