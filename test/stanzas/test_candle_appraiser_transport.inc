(test
 (name test_candle_appraiser_transport)
 (modules test_candle_appraiser_transport)
 (deps
  ../config/prompts/candle_appraiser_grade.md
  ../config/prompts/candle_appraiser_relation.md
  ../config/prompts/candle_appraiser_weights.md)
 (libraries masc_test_deps masc.server masc_candle exact_output_fixture))
