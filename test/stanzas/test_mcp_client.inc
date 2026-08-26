(test
 (name test_mcp_client)
 (modules test_mcp_client)
 (libraries alcotest yojson masc.mcp_client masc.http_client
   masc.mcp_transport_protocol))
