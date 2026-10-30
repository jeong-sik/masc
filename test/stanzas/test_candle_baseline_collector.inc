(rule
 (alias runtest-test_candle_baseline_collector)
 (deps test_candle_baseline_collector.py
       ../docs/evidence/2026-09-29-candle-baseline/collect.py)
 (action (run python3 %{dep:test_candle_baseline_collector.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_candle_baseline_collector)))
