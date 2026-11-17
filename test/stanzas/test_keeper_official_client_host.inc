(test
 (name test_keeper_official_client_host)
 (modules test_keeper_official_client_host)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc masc_test_deps))
