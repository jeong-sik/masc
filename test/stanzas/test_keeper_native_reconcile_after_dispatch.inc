; Runs a real Core execution whose host receipt sink fails, so the journal holds
; a terminal while the Owner call stays Active, then reconciles it.
(test
 (name test_keeper_native_reconcile_after_dispatch)
 (modules test_keeper_native_reconcile_after_dispatch)
 (libraries masc_test_deps exact_output_fixture eio_main unix masc.keeper_checkpoint_ref masc.agent_core.llm_provider))
