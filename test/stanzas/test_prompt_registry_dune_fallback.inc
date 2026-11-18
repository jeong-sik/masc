(test
 (name test_prompt_registry_dune_fallback)
 (modules test_prompt_registry_dune_fallback)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps eio.unix))
