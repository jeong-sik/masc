(test
 (name test_keeper_muse_runtime)
 (modules test_keeper_muse_runtime)
 (deps (source_tree ../config/prompts))
 (libraries masc masc_test_deps masc.keeper_chat_operations masc.keeper_execution_scope
  masc.keeper_checkpoint_ref masc.keeper_registry))

(rule
 (alias runtest-test_keeper_muse_async_outbox)
 (action (run %{exe:test_keeper_muse_runtime.exe} test "async result outbox")))
