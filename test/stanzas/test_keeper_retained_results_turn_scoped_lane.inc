; Retained tool results ride a request without breaking the turn-scoped
; context that closes it.

(test
 (name test_keeper_retained_results_turn_scoped_lane)
 (modules test_keeper_retained_results_turn_scoped_lane)
 (libraries alcotest masc masc_test_deps eio_main yojson))
