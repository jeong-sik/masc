; Keeper OAS raw-trace wiring guard: keeper dispatch must pass ~raw_trace
; into Keeper_turn_driver.run_named (dead ?raw_trace regression), and the
; per-keeper sink must append across turns at the SSOT path
; (.masc/keepers/<name>/raw-trace.jsonl).

(test
 (name test_keeper_raw_trace_sink)
 (modules test_keeper_raw_trace_sink)
 (libraries masc_test_deps))
