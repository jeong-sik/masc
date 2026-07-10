; Behavioral coverage for the wire-capture response-suppression surface
; (Keeper_agent_run_finalize_response.wire_capture_response_suppression_reasons
; + emit_wire_capture_response_suppressed_metrics + replay_response_text_for_capture,
; Keeper_agent_run_response_text budget/attention auto-suppress). Restored after
; PR #23929's [STATE]/BDI purge deleted test/test_keeper_state_snapshot_json.ml
; and swept this unrelated, still-live coverage out with it (post-merge audit P1
; finding: 0 remaining behavioral test consumers).

(test
 (name test_keeper_wire_capture_suppression)
 (modules test_keeper_wire_capture_suppression)
 (libraries masc_test_deps))
