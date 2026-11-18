; Only a structured report_review_verdict tool call may produce a semantic
; task-completion verdict.

(test
 (name test_anti_rationalization_empty_reject)
 (modules test_anti_rationalization_empty_reject)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps))
