; Coding-outcome eval (RFC-0396) — shared case/report modules as a library
; so the report CLI and the corpus contract test link the same code.

(library
 (name coding_eval_lib)
 (wrapped false)
 (modules coding_eval_case coding_eval_report)
 (libraries masc_test_deps))
