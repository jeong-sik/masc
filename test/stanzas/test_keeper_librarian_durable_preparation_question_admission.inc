(test
 (name test_keeper_librarian_durable_preparation_question_admission)
 (modules test_keeper_librarian_durable_preparation_question_admission)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest astring masc_test_deps masc agent_core))
