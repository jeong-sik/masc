(test
 (name test_runtime_official_client_mcp_http)
 (modules test_runtime_official_client_mcp_http)
 (libraries masc masc_test_deps))

(rule
 (alias runtest-test_runtime_official_client_mcp_http_response_delivery)
 (action (run %{exe:test_runtime_official_client_mcp_http.exe} test "response delivery")))

(rule
 (alias runtest-test_runtime_official_client_mcp_http_tool_scheduling)
 (action (run %{exe:test_runtime_official_client_mcp_http.exe} test "tool scheduling")))
