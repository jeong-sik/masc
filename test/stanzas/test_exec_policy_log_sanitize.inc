; Pins what Exec_policy_log_sanitize hides in a logged command: every
; key=value word and every word after a sensitive flag, regardless of case.

(test
 (name test_exec_policy_log_sanitize)
 (modules test_exec_policy_log_sanitize)
 (libraries masc_test_deps))
