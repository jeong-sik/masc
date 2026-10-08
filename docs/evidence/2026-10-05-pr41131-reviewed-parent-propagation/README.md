# PR #41131 reviewed parent propagation

Clean real merge of published #41130 `b249888c3f2bd740a6fd02477d57619c2f6de6c5` into `bd414e75e63dc817d9e8aa2adab4fb06c8af7852`. Native Stack #41123 position 7 remains unchanged. Unique source/test scope is retained; the sole overlapping own source change accepts loader-supported `.toml` filenames. Deleted old table modules stay deleted. Typed owner revision, removal guards, exact configuration authority and retained identity checks flow from the parent. No independent implementation change.

Actual focused wrapper build of `bin/masc_tui.exe test/test_tui_lane_inventory.exe` passed (handle 64406), then the full TUI inventory target passed. Exact output and binary hash are retained here. Parent's 25 native/78 Web checks are not claimed as new executions. Existing MSX retry, declaration editor and input precedence source remain intact; no repeated PTY or full suite.
