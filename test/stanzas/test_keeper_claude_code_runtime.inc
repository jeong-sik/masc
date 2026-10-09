(test
 (name test_keeper_claude_code_runtime)
 (modules test_keeper_claude_code_runtime)
 (deps fixtures/claude_code/cc-2.1.280-two-request-turn.jsonl)
 (libraries native_tool_outcome_fixture masc masc_test_deps))
