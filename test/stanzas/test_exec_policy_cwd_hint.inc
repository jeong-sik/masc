; Pins explicit cwd/redirect containment, opaque positional argv, and the
; filesystem-grounded Cwd_not_directory hint.

(test
 (name test_exec_policy_cwd_hint)
 (modules test_exec_policy_cwd_hint)
 (libraries masc_test_deps))
