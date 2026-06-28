; Invalid snapshot goals are counted every time but WARN-logged only
; once per keeper/goal hash, without dumping raw persona goal text.

(test
 (name test_keeper_post_turn_snapshot_goal_log)
 (modules test_keeper_post_turn_snapshot_goal_log)
 (libraries masc_test_deps))
