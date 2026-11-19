; Pure state-machine tests for the Slack Socket Mode FSM.
; Same minimal deps as test_discord_gateway_state.inc.
(test
 (name test_slack_gateway_state)
 (modules test_slack_gateway_state)
 (libraries alcotest masc.gate))
