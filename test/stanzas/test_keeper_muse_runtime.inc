(test
 (name test_keeper_muse_runtime)
 (modules test_keeper_muse_runtime)
 (libraries masc masc_test_deps))

(rule
 (alias runtest-test_keeper_muse_async_outbox)
 (action (run %{exe:test_keeper_muse_runtime.exe} test "async result outbox")))
