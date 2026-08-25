; RFC-0366. The lifetime is the contract: a note renders once and the record
; stays. A note that renders twice is the defect this store prevents.

(test
 (name test_keeper_operator_note)
 (modules test_keeper_operator_note)
 (libraries alcotest astring masc masc_test_deps unix))
