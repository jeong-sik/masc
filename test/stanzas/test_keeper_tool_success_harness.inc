; Deterministic keeper tool success harness for the Tool Execution Substrate
; implementation plan.  Kept outside the legacy grouped stanza to avoid
; conflict-cascade hotspots.

(test
 (name test_keeper_tool_success_harness)
 (modules test_keeper_tool_success_harness)
 (libraries masc_test_deps))
