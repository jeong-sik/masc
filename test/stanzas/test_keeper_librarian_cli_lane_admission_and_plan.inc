(test
 (name test_keeper_librarian_cli_lane_admission_and_plan)
 (modules test_keeper_librarian_cli_lane_admission_and_plan)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries
  masc_test_deps
  exact_output_fixture
  masc
  masc.runtime
  masc.masc_eio_context
  agent_core
  eio_main))
