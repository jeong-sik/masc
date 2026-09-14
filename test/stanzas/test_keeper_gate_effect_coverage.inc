(test
 (name test_keeper_gate_effect_coverage)
 (modules test_keeper_gate_effect_coverage)
 ; exec_shim: task-1568 regression pin (test_user_notif_capability_does_not_
 ; change_observed_refused_decision) links the capability probe added there
 ; to prove it does not leak into an allow path here.
 (libraries masc_test_deps exec_shim))
