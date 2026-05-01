; Regression for readonly_hint_of_category — every named category
; must carry a concrete Good:/Bad: example so small-LLM keepers can
; self-correct (#8688 root-cause sweep follow-up).

(test
 (name test_keeper_readonly_hints)
 (modules test_keeper_readonly_hints)
 (libraries masc_test_deps))
