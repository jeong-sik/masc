; Boot recovery settles admission-time in-flight turns instead of parking
; operations in the exitless Reconciliation_required phase (#25491).

(test
 (name test_keeper_shutdown_reconciliation_settlement)
 (modules test_keeper_shutdown_reconciliation_settlement)
 (libraries masc_test_deps))
