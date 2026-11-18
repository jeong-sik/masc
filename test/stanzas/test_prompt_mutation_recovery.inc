(test
 (name test_prompt_mutation_recovery)
 (modules test_prompt_mutation_recovery)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc.prompt_registry masc.masc_core masc.fs_compat alcotest eio eio_main unix))
