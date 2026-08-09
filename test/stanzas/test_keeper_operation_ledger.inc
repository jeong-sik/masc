(test
 (name test_keeper_operation_ledger)
 (modules test_keeper_operation_ledger)
 (libraries alcotest eio eio_main masc.fs_compat masc.keeper_operation sqlite3 unix))
