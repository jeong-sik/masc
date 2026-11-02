(test
 (name test_checkpoint_inspection_cli)
 (modules test_checkpoint_inspection_cli)
 (libraries masc_test_deps masc.keeper_registry masc.agent_core.llm_provider)
 (deps ../bin/main_eio.exe)
 (action
  (setenv MASC_TEST_MASC_EXE %{dep:../bin/main_eio.exe}
   (run %{test}))))
