; Runtime-manifest parsing + failover-mode classification for the keeper
; canary harness --inject-failover (lib/keeper_canary/keeper_canary_failover.ml,
; masc task-12, M2 PR-C). The live runtime-trace fetch stays in bin/.

(test
 (name test_keeper_canary_failover)
 (modules test_keeper_canary_failover)
 (libraries masc_test_deps))
