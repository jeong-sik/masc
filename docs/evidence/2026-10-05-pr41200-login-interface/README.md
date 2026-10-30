# Account-login interface and fixture validation (#41200)

Original PR head `d5b0c3e1008a5d0ef4b91ea88a02bd1f706eabe5` was compiled in
this new isolated worktree using the focused resource-limited wrapper. The
original target ran 42 tests: 40 passed and two failed. Both individual failure
outputs are retained. This independently confirms the author's test counts; it
does not repeat the author's historical 6fc062fe build or main compile failure.

The two failures are stale fixture lifecycle, not evidence of a production
retry regression. `Login.saved` enters `Finished / Activating`; `key` correctly
returns `Nothing` there. The real dispatcher calls `Login.activated` before
launching `Refresh_saved` (bin/masc_tui.ml). The two fixtures omitted that event.
They now check the real successful activation receipt before injecting the
inventory read failure. Every existing durability/lock warning, diagnostic
privacy, malformed receipt, and refresh-only retry assertion remains unchanged.
No production implementation changed. Main and the original PR have byte-identical
implementation, test and build inputs listed in main-source-comparison.json;
this is a source comparison, not an extra baseline execution.

The same focused target was rebuilt and ran all 42 tests successfully. The
fragment parser and non-evidence diff whitespace check passed. Build logs contain
existing macOS Keychain deprecation warnings. Source, binary and raw artifact
hashes are in checks.json. This is native focused test proof, not a full build,
full suite, TUI PTY, browser, hosted CI, deployed runtime or release verdict.

Read-only issue searches for the two assertion phrases and account-login retry
found no specific duplicate. The fixture issue is repaired here rather than
recorded as an unverified product regression. No GitHub issue/comment was posted.
