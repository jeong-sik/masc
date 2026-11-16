(test
 (name test_keeper_identity_gate)
 (modules test_keeper_identity_gate)
 (libraries alcotest base64 str unix yojson agent_core masc masc.server masc.http_client
   masc.keeper_identity masc.keeper_contract
   masc.keeper_runtime masc.tool_types masc.masc_tool_dispatch masc.mcp_client
   masc.mcp_transport_protocol masc_test_deps))
