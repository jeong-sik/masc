; slack-lane reader tool (task-1430) — handler-level tests over the seeded
; in-memory lane buffer. Same minimal deps as the poll-lane stanza.
(test
 (name test_slack_read_tool)
 (modules test_slack_read_tool)
 (libraries alcotest yojson masc masc.slack_lane))
