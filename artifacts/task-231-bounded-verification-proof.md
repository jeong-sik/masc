# task-231 bounded verification proof

Implementation is based on PR #28206 head `e5372ae36294fd3755b1545bc574a009a686b636`.

The source-level evidence is intentionally adjacent to `contains_any` near the
start of `test/test_mcp_tool_matrix_cases.ml`, within the bounded artifact
prefix:
- `contains_any` calls `String_util.contains_substring_ci`.
- The nearby fixtures include `Internal Error: provider failed` versus
  `internal error`, and `Already Joined` versus `already joined`.
- `regression_case_insensitive_matching` checks both fixtures.
- `For_testing` exports the matcher and regression for the dedicated test.

Verification:
- `ocamlformat --check test/test_mcp_tool_matrix_cases.ml test/test_mcp_tool_matrix_matching.ml` -> exit 0.
- `git diff --check` -> exit 0.
- `bash scripts/dune-local.sh build test/test_mcp_tool_matrix_matching.exe` -> exit 0.
- `bash scripts/dune-local.sh exec test/test_mcp_tool_matrix_matching.exe` -> exit 0; 2 tests passed.
