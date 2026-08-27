(test
 (name test_keeper_identity_gate)
 (modules test_keeper_identity_gate)
 (libraries alcotest str unix yojson agent_core masc masc.http_client
   masc.keeper_identity masc.mcp_client masc.mcp_transport_protocol
   masc_test_deps))
