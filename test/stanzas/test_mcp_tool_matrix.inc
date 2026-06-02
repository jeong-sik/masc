; MCP Tool Matrix (2 modules + generated names + runner dep)

(test
 (name test_mcp_tool_matrix)
 (modules test_mcp_tool_matrix)
 (deps tool_matrix_case_runner.exe)
 (libraries masc_test_deps keeper_tool_matrix_cases_lib))
