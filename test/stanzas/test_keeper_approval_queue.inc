(test
 (name test_keeper_approval_queue)
 (modules test_keeper_approval_queue)
 (libraries alcotest masc masc.keeper_approval masc.keeper_checkpoint_ref masc_test_deps eio_main))

(test
 (name test_keeper_native_continuation_projection)
 (modules test_keeper_native_continuation_projection)
 (libraries alcotest masc masc.keeper_approval masc_test_deps))
