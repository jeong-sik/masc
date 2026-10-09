(test
 (name test_runtime_claude_code)
 (modules test_runtime_claude_code)
 (deps fixtures/claude_code/cc-2.1.280-two-request-turn.jsonl)
 (libraries masc masc.runtime masc_test_deps))
