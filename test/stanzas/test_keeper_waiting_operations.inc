; Chat requests queued behind a Keeper's running turn. The count is told to the
; running turn once, a request that failed tells it again, and a store that
; cannot be read gives no count.

(test
 (name test_keeper_waiting_operations)
 (modules test_keeper_waiting_operations)
 (libraries alcotest astring masc masc_test_deps))
