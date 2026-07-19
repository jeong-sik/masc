; Slack gateway external-attention durable round trips (triggered + ambient).
; Links masc_test_deps for masc.server (Server_slack_*).
(test
 (name test_server_slack_gateway_attention)
 (modules test_server_slack_gateway_attention)
 (libraries alcotest masc masc_test_deps))
