; Masc_data_root pin contract (RFC-checkpoint-pinned-root-containment
; PR-1, #25151): physical resolution, set-once refusal of a differing
; repin, typed unresolvable/non-directory failures.

(test
 (name test_masc_data_root)
 (modules test_masc_data_root)
 (libraries masc_test_deps))
