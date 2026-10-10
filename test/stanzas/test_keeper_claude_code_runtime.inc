(test
 (name test_keeper_claude_code_runtime)
 (modules test_keeper_claude_code_runtime)
 (deps fixtures/claude_code/cc-2.1.280-two-request-turn.jsonl)
 (libraries masc.fs_compat masc_tui_keeper_chat_transcript masc_tui_keeper_chat_log native_tool_outcome_fixture masc masc_test_deps))
