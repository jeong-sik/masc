(test
 (name test_endpoint_mixed_admission)
 (modules test_endpoint_mixed_admission)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc masc.fusion_core masc.fs_compat masc.masc_eio_context))
