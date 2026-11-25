(test
 (name test_official_client_claim_cause)
 (modules test_official_client_claim_cause)
 (deps masc-antigravity-path-hook (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc masc_test_deps unix))
