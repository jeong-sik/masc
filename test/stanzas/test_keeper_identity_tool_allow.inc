(test
 (name test_keeper_identity_tool_allow)
 (modules test_keeper_identity_tool_allow)
 (libraries alcotest unix yojson agent_core masc masc.http_client
   masc.keeper_identity masc.mcp_client masc.mcp_transport_protocol))
