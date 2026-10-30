; Boot recovery replays a Blocked shutdown at a stage that released the
; admission fence, or closes it with a warning when it was overtaken (#38859).

(test
 (name test_keeper_shutdown_blocked_replay)
 (modules test_keeper_shutdown_blocked_replay)
 (libraries masc_test_deps))
