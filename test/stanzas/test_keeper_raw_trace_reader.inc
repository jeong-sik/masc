; Raw traces become readable from outside the host here. The containment cases
; assert that a caller-supplied file name cannot leave the keeper's directory.

(test
 (name test_keeper_raw_trace_reader)
 (modules test_keeper_raw_trace_reader)
 (libraries alcotest astring masc masc_test_deps unix))
