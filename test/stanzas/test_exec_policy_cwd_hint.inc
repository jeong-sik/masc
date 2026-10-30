; Pins explicit cwd/redirect containment, opaque positional argv, and the
; filesystem-grounded Cwd_not_directory hint.

(test
 (name test_exec_policy_cwd_hint)
 (modules test_exec_policy_cwd_hint)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps))
