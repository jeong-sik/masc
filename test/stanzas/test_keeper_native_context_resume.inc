(test
 (name test_keeper_native_context_resume)
 (modules test_keeper_native_context_resume)
 (libraries masc_test_deps exact_output_fixture masc.masc_core masc.agent_core
  masc.keeper_chat_operations masc.keeper_registry masc.keeper_checkpoint_ref
  eio_main fs_compat unix yojson uuidm))
