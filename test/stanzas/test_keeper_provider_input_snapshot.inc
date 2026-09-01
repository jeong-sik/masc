; Exact-turn provider input snapshots: artifact round trip, turn binding, and
; content-addressed deduplication across repeated history.

(test
 (name test_keeper_provider_input_snapshot)
 (modules test_keeper_provider_input_snapshot)
 (libraries alcotest masc masc_test_deps unix))
