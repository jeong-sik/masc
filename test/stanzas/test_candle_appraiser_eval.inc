(rule
 (alias runtest-test_candle_appraiser_eval)
 (deps
  ../scripts/candle-appraiser-eval.py
  candle_appraiser_eval_cli.exe
  test_candle_appraiser_eval.py
  fixtures/candle_appraiser_eval_cases.json
  ../config/prompts/candle_appraiser_grade.md
  ../config/prompts/candle_appraiser_relation.md
  ../config/prompts/candle_appraiser_weights.md)
 (action (run python3 %{dep:test_candle_appraiser_eval.py}
  --binary %{exe:candle_appraiser_eval_cli.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_candle_appraiser_eval)))
