(test
 (name test_keeper_input_birth)
 (modules test_keeper_input_birth)
 (libraries masc_test_deps masc.masc_core masc.keeper_chat_operations
  masc.keeper_registry masc.keeper_checkpoint_ref masc.agent_core fs_compat
  alcotest unix sqlite3 yojson eio eio_main))
