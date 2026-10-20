; Stops the Owner inventory while a real Core execution waits on its provider,
; then checks the native call receipt the stopped Owner settled.
(test
 (name test_keeper_native_receipt_during_stop)
 (modules test_keeper_native_receipt_during_stop)
 (libraries masc_test_deps exact_output_fixture eio_main unix masc.keeper_checkpoint_ref masc.agent_core.llm_provider))
