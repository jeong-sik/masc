(test
 (name test_candle_appraisal_flow)
 (modules test_candle_appraisal_flow)
 (deps
  ../config/prompts/candle_appraiser_grade.md
  ../config/prompts/candle_appraiser_relation.md
  ../config/prompts/candle_appraiser_weights.md)
 (libraries masc_test_deps masc_candle masc_candle_store masc_candle_runtime masc.server))
