; Evidence JSON schema for the keeper canary harness
; (bin/keeper_canary_run.ml, masc task-11, M1 PR1).

(test
 (name test_keeper_canary_evidence)
 (modules test_keeper_canary_evidence)
 (libraries masc_test_deps))
