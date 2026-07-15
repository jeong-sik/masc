; RFC-0225 §3.2: the checkpoint transaction refuses writes whose turn_count is
; older than the last saved one (stale-writer clobber guard, 2026-06-10
; voice incident).

(test
 (name test_keeper_checkpoint_stale_guard)
 (modules test_keeper_checkpoint_stale_guard)
 (libraries masc_test_deps))
