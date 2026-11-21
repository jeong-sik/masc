(test
 (name test_keeper_official_client_host_continuity_observation)
 (modules test_keeper_official_client_host_continuity_observation)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc masc_test_deps))
