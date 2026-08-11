# task-231 bounded verification proof

Base: PR #28206 head `e5372ae36294fd3755b1545bc574a009a686b636`; implementation commit `c066c651720d188d75067d9ab937e16476386012`.

Source evidence from `test/test_mcp_tool_matrix_cases.ml`:
- `contains_any haystack needles` calls
  `String_util.contains_substring_ci haystack needle`.
- Regression fixtures include
  `("fatal", "Internal Error: provider failed", ["internal error"])`
  and `("guard", "Already Joined", ["already joined"])`.
- `regression_case_insensitive_matching` fails if either mixed-case response
  does not match its lowercase fragment.
- `test/test_mcp_tool_matrix_matching.ml` runs that regression and a direct
  `Already Joined` / `already joined` assertion.

Verification:
- `ocamlformat --check test/test_mcp_tool_matrix_cases.ml test/test_mcp_tool_matrix_matching.ml` -> exit 0.
- `git diff --check` -> exit 0.
- `bash scripts/dune-local.sh build test/test_mcp_tool_matrix_matching.exe` -> exit 0.
- `bash scripts/dune-local.sh exec test/test_mcp_tool_matrix_matching.exe` -> exit 0; 2 tests passed.
