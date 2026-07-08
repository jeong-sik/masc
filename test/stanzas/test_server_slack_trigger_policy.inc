; RFC-0317 — server Slack trigger-policy parser delegates to the single strict
; grammar. Links masc_test_deps for masc.server (Server_slack_*).
(test
 (name test_server_slack_trigger_policy)
 (modules test_server_slack_trigger_policy)
 (libraries alcotest masc_test_deps))
