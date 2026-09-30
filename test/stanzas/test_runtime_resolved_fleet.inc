; GET /api/v1/runtime/resolved over a fixture keeper directory: one assignment
; row per keeper and the lanes those rows resolve to.

(test
 (name test_runtime_resolved_fleet)
 (modules test_runtime_resolved_fleet)
 (libraries alcotest masc masc_test_deps))
