; Drives the Owner with a child that ends while its native call is Active.
; MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false for the same reason as
; test_keeper_owner: the fixtures declare docker, and the preflight is not
; what this suite measures.
(test
 (name test_keeper_owner_open_native_call)
 (modules test_keeper_owner_open_native_call)
 (action
  (setenv MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED false (run %{test})))
 (libraries masc_test_deps masc.keeper_checkpoint_ref masc.keeper_execution_scope masc.agent_core.llm_provider))
