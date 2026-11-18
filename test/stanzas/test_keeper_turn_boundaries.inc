; The turn boundary log: one line per finished keeper turn, saying where the
; saved atom history ended, and one line whenever a turn or a clear started
; that history over.

(test
 (name test_keeper_turn_boundaries)
 (modules test_keeper_turn_boundaries)
 (libraries goal_measure_fixture masc.goal_measure masc_test_deps))
