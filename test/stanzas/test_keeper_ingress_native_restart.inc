(test
 (name test_keeper_ingress_native_restart)
 (modules test_keeper_ingress_native_restart)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps exact_output_fixture eio_main unix))
