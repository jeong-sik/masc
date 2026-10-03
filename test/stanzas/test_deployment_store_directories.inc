(test
 (name test_deployment_store_directories)
 (modules test_deployment_store_directories)
 (libraries masc_test_deps)
 (deps ../bin/deployment_preflight_helper.exe)
 (action
  (setenv MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE %{dep:../bin/deployment_preflight_helper.exe}
   (run %{test}))))
