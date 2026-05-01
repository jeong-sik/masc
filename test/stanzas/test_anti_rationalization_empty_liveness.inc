; Precondition pin: parse_verdict "" must return exactly
; Error "empty review output" so the liveness-approve branch in
; Anti_rationalization.review keeps matching (#8688).

(test
 (name test_anti_rationalization_empty_liveness)
 (modules test_anti_rationalization_empty_liveness)
 (libraries masc_test_deps))
