; slack-lane (task-1418) — pure unit tests for the collection contract:
; page parsing, filter, ring buffer dedupe/trim, fail-closed config knob.
(test
 (name test_slack_poll_lane)
 (modules test_slack_poll_lane)
 (libraries alcotest masc.gate masc.slack_lane masc.server))
