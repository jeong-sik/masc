(test
 (name test_deployment_store_directories)
 (modules test_deployment_store_directories)
 (libraries masc_test_deps)
 (deps ../bin/deployment_preflight_helper.exe)
 (action
  (setenv MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE %{dep:../bin/deployment_preflight_helper.exe}
   (run %{test}))))

; Run the shell gate against the same compiled helper as the decoder fixtures.
(rule
 (alias runtest-test_runtime_deployment_preflight)
 (deps
  ../bin/deployment_preflight_helper.exe
  ../scripts/check-runtime-deployment-preflight.sh
  ../lib/keeper/keeper_board_attention_candidate.ml)
 (action
  (setenv MASC_DEPLOYMENT_PREFLIGHT_HELPER %{dep:../bin/deployment_preflight_helper.exe}
   (run bash %{dep:../scripts/check-runtime-deployment-preflight.sh} --self-test))))
