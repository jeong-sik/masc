(test
 (name test_keeper_input_birth)
 (modules test_keeper_input_birth)
 (libraries masc_test_deps masc.keeper_chat_operations
  masc.keeper_registry masc.keeper_checkpoint_ref masc.agent_core fs_compat
  alcotest unix sqlite3 eio eio_main))
