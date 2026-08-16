; Serving-runtime attribution verdicts for the canary harness
; (lib/keeper_canary/keeper_canary_serving.ml, #28913): the check that a
; receipt's turns were completed by the runtime the run claims to measure.
; Born from the M3 sweep incident where degraded retry silently served
; eight "antigravity" canaries from ollama_cloud (#28912).

(test
 (name test_keeper_canary_serving)
 (modules test_keeper_canary_serving)
 (libraries masc_test_deps))
