(test
 (name test_kimi_coding_replay)
 (modules test_kimi_coding_replay)
 (libraries masc_test_deps)
 (deps ../config/runtime.toml ../packages/agent_core/models.toml)
 (action
  (setenv MASC_TEST_RUNTIME_SEED %{dep:../config/runtime.toml}
   (setenv MASC_TEST_MODEL_CATALOG %{dep:../packages/agent_core/models.toml}
    (run %{test})))))
