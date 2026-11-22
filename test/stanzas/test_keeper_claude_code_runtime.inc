(test
 (name test_keeper_claude_code_runtime)
 (modules test_keeper_claude_code_runtime)
 (deps fixtures/claude_code/cc-2.1.280-two-request-turn.jsonl (source_tree %{workspace_root}/config/prompts))
 (libraries masc.fs_compat masc.time_codec native_tool_outcome_fixture masc masc_server dated_jsonl masc_test_deps))

(rule
 (alias runtest-test_keeper_claude_async_outbox)
 (action (run %{exe:test_keeper_claude_code_runtime.exe} test "async result outbox")))

(rule
 (alias runtest-test_keeper_claude_selected_inference)
 (action (run %{exe:test_keeper_claude_code_runtime.exe} test "selected inference")))

(rule
 (alias runtest-test_keeper_claude_effort_authority)
 (action (run %{exe:test_keeper_claude_code_runtime.exe} test "native effort authority")))
