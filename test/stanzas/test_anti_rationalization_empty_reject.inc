; Only a structured report_review_verdict tool call may produce a semantic
; task-completion verdict.

(test
 (name test_anti_rationalization_empty_reject)
 (modules test_anti_rationalization_empty_reject)
 (libraries masc_test_deps))
