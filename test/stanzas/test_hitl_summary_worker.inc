(test
 (name test_hitl_summary_worker)
 (modules test_hitl_summary_worker)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries
  alcotest
  masc
  masc_test_deps
  exact_output_fixture
  eio_main
  unix))
