; Nonce fact generation + turn-plan construction + recall scoring for the
; keeper canary harness (bin/keeper_canary_run.ml, masc task-11, M1 PR1).

(test
 (name test_keeper_canary_facts)
 (modules test_keeper_canary_facts)
 (libraries masc_test_deps))
