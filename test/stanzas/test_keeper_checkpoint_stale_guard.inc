; The checkpoint transaction refuses writes whose turn_count is
; older than the last saved one (stale-writer clobber guard, 2026-06-10
; voice incident).

(test
 (name test_keeper_checkpoint_stale_guard)
 (modules test_keeper_checkpoint_stale_guard)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc.keeper_checkpoint_ref))
