; slack-lane reader tool (task-1430) — handler-level tests over the seeded
; in-memory lane buffer and actual misc dispatch/descriptor registration.
(test
 (name test_slack_read_tool)
 (modules test_slack_read_tool)
 (libraries
  alcotest yojson fs_compat masc masc.slack_lane
  masc.tool_types masc.masc_tool_dispatch masc.tool_schemas masc.masc_types))
