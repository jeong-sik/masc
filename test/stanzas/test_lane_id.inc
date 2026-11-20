; Lane_id, Lane_manifest and Standalone_lane.obligation: every built-in lane
; has one wire id that reads back, and the manifest functions cover each one.
(test
 (name test_lane_id)
 (modules test_lane_id)
 (libraries alcotest masc masc.browser_lane masc.runtime masc.tool_schemas masc_test_deps))
