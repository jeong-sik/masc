# task-231 verification proof

- Base: PR #28206 head `e5372ae36294fd3755b1545bc574a009a686b636`.
- Source: `test/test_mcp_tool_matrix_cases.ml` now uses `String_util.contains_substring_ci` inside `contains_any`, preserving case-insensitive fragment matching.
- Regression coverage: mixed-case `Internal Error: provider failed` matches lowercase `internal error`; mixed-case `Already Joined` matches lowercase `already joined`.
- Test: `bash scripts/dune-local.sh build test/test_mcp_tool_matrix_matching.exe` — exit 0.
- Test: `bash scripts/dune-local.sh exec test/test_mcp_tool_matrix_matching.exe` — exit 0, 2 tests passed.
- Format: `ocamlformat --check test/test_mcp_tool_matrix_cases.ml test/test_mcp_tool_matrix_matching.ml` — exit 0.
- Diff: `git diff --check` — exit 0.
