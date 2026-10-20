; Runs a real Core execution with several tool rounds through the native
; adapter and checks that the retained directory holds only named checkpoints.
(test
 (name test_keeper_native_checkpoint_release)
 (modules test_keeper_native_checkpoint_release)
 (libraries masc_test_deps exact_output_fixture eio_main unix masc.keeper_checkpoint_ref masc.agent_core.llm_provider))
