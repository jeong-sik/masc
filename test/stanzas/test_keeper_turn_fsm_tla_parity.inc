(test
 (name test_keeper_turn_fsm_tla_parity)
 (modules test_keeper_turn_fsm_tla_parity)
 (deps %{project_root}/specs/keeper-turn-fsm/KeeperTurnFSM.tla)
 (libraries alcotest masc masc_test_deps masc.masc_turn))
