; The status line and the body are worded from config/prompts at run time
; (see test_keeper_memory_recall_render.inc).
(test
 (name test_keeper_memory_recall_blocks)
 (modules test_keeper_memory_recall_blocks)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc alcotest masc_test_deps eio_main))
