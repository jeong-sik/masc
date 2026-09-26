(test
 (name test_deployment_runtime_config)
 (modules test_deployment_runtime_config)
 (libraries masc_test_deps)
 (deps ../bin/deployment_preflight_helper.exe ../config/runtime.toml)
 (action
  (setenv MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE %{dep:../bin/deployment_preflight_helper.exe}
   (setenv MASC_TEST_RUNTIME_SEED %{dep:../config/runtime.toml}
    (run %{test})))))
