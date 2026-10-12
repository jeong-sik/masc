(test
 (name test_keeper_identity_tools)
 (modules test_keeper_identity_tools)
 (libraries alcotest str unix yojson eio_main agent_core masc masc.http_client
   masc.keeper_identity masc.mcp_client masc.mcp_transport_protocol))
