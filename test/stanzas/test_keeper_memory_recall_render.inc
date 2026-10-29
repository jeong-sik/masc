; The sentences are read from config/prompts through DUNE_SOURCEROOT at run
; time, so the directory is a dependency: a commit that touches only keeper.md
; has to run this test again (see test_prompt_templates_render.inc).
(test
 (name test_keeper_memory_recall_render)
 (modules test_keeper_memory_recall_render)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc alcotest masc_test_deps))
