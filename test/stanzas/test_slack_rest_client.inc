; RFC-0317 Slack_rest_client pure-helper tests.
; Same minimal-deps stanza as test_discord_rest_client.
(test
 (name test_slack_rest_client)
 (modules test_slack_rest_client)
 (libraries alcotest yojson masc.gate))
