(test
 (name test_keeper_antigravity_runtime)
 (modules test_keeper_antigravity_runtime)
 (libraries masc masc_test_deps))

(rule
 (alias runtest-test_keeper_antigravity_async_outbox)
 (action (run %{exe:test_keeper_antigravity_runtime.exe} test "async result outbox")))
