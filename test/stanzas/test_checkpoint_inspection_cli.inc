(test
 (name test_checkpoint_inspection_cli)
 (modules test_checkpoint_inspection_cli)
 (libraries masc_test_deps masc.agent_core.llm_provider)
 (deps ../bin/main_eio.exe test_keeper_checkpoint_smoke.py ../scripts/keeper-first-turn-smoke.py)
 (action
  (setenv MASC_TEST_MASC_EXE %{dep:../bin/main_eio.exe}
   (setenv MASC_TEST_SMOKE_PY %{dep:test_keeper_checkpoint_smoke.py}
    (run %{test})))))
