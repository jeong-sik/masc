; The turn boundary log: one line per finished keeper turn, saying where the
; saved atom history ended, and one line whenever a turn or a clear started
; that history over.

(test
 (name test_keeper_turn_boundaries)
 (modules test_keeper_turn_boundaries)
 (libraries masc_test_deps))
