(test
 (name test_keeper_librarian_request_unread)
 (modules test_keeper_librarian_request_unread)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc.prompt_registry))
