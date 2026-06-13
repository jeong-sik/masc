; RFC-0203 Phase 2 — Discord_rest_client pure-helper tests.
; Same minimal-deps stanza as test_discord_gateway_state to stay
; insulated from main breakage in the masc_test_deps superset.
(test
 (name test_discord_rest_client)
 (modules test_discord_rest_client)
 (libraries alcotest yojson masc.gate))
