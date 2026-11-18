(test
 (name test_candle_payout_owed)
 (modules test_candle_payout_owed)
 (libraries goal_measure_fixture masc.goal_measure
  masc_test_deps
  masc_candle
  masc_candle_store
  masc_candle_config
  masc_candle_runtime
  ptime))
