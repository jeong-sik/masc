(rule
 (alias runtest-test_candle_appraiser_eval)
 (deps
  ../scripts/candle-appraiser-eval.py
  test_candle_appraiser_eval.py
  fixtures/candle_appraiser_eval_cases.json
  ../config/prompts/candle_appraiser_grade.md
  ../config/prompts/candle_appraiser_relation.md
  ../config/prompts/candle_appraiser_weights.md)
 (action (run python3 %{dep:test_candle_appraiser_eval.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_candle_appraiser_eval)))
