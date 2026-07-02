; Keeper OAS raw-trace wiring guard: keeper dispatch must pass ?raw_trace
; into Keeper_turn_driver.run_named (dead ?raw_trace regression), the
; per-turn store (.masc/keepers/<name>/raw-traces/turn-*.jsonl) must stay
; bounded and immune to corrupt history, and a degraded trace store must
; dispatch the turn untraced instead of failing it (PR #22984 review).

(test
 (name test_keeper_raw_trace_sink)
 (modules test_keeper_raw_trace_sink)
 (libraries masc_test_deps))
