; Judge prompt composition + strict verdict parsing for the keeper canary
; harness LLM judge (lib/keeper_canary/keeper_canary_judge.ml, masc task-11,
; M1 PR2). The live provider subcall stays in bin/keeper_canary_run.ml.

(test
 (name test_keeper_canary_judge)
 (modules test_keeper_canary_judge)
 (libraries masc_test_deps))
