; Board persistence loader Result.t contract (load_persisted_{posts,comments})

(test
 (name test_board_persistence_load_contract)
 (modules test_board_persistence_load_contract)
 (libraries masc_test_deps))
