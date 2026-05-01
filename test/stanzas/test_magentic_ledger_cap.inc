; Gen13 second-model coverage: Magentic ledger v1 overlays the
; narrative fields after Bdi returns; this test locks the cap
; invariant at the emission point so both speech models honour the
; same budget.

(test
 (name test_magentic_ledger_cap)
 (modules test_magentic_ledger_cap)
 (libraries masc_test_deps))
