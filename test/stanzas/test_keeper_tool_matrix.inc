; Keeper Tool Matrix (test driver + runner dep)

(test
 (name test_keeper_tool_matrix)
 (modules test_keeper_tool_matrix)
 (deps keeper_tool_matrix_case_runner.exe)
 (libraries masc_test_deps keeper_tool_matrix_cases_lib))
