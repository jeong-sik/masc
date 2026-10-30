; Slack_user_directory cache + mention-rewrite tests (issue #28376).
; Same minimal-deps stanza as test_slack_rest_client.
(test
 (name test_slack_user_directory)
 (modules test_slack_user_directory)
 (libraries alcotest yojson masc.gate))
