(test
 (name test_keeper_native_uncollected_restart)
 (modules test_keeper_native_uncollected_restart)
 (libraries masc_test_deps exact_output_fixture masc.agent_core
  masc.keeper_chat_operations masc.keeper_registry masc.keeper_checkpoint_ref
  eio_main fs_compat unix))
