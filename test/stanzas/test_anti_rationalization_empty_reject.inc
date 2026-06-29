; Empty evaluator output is a typed parser error and Anti_rationalization.review
; must reject it through format_reject instead of approving by liveness.

(test
 (name test_anti_rationalization_empty_reject)
 (modules test_anti_rationalization_empty_reject)
 (libraries masc_test_deps))
