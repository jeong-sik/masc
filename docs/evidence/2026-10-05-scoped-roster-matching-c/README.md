# Scoped roster successor coverage

Parent: #41195 `e341428afdb11ad7c54c1a58dd2b3c501f2db047`.
This fixture-only followup restores the matching-C positive coverage from frozen #40851/#40860 while preserving the current foreign-C/Board negative case. No product source changes.

Both cases hold B's scoped roster, apply a newer full C identity before releasing B, wait for selectable `c-only`, and reject every `b-only` byte after the C boundary. The existing foreign-C case still asserts Board refuses an unverified workspace. The added matching-C case seeds real local `c-only` metadata and uses the prepared workspace's exact health identity, then requires no mismatch before releasing B. Both run from the script's normal entrypoint; this is not a replacement or exclusion.

## Actual verification

Retained exact-main-6fc TUI SHA256 `196d9fce8ecced88ab44ac424d300d9744299ee1f707d323eac9c0803d7bae0e`; no rebuild. Synthetic HTTP through the actual TUI PTY, not live production proof.

Baseline foreign-C case PASS (empty successful raw log). First matching-C-only case PASS. An extra attempted 80-column full-mismatch-badge barrier failed before holding the roster; this is retained in `final-pty.log`, not presented as a product RED. That extra assertion was removed, restoring the already passing original matching-C proof. Final shared implementation ran both foreign-C and matching-C cases PASS in `both-pty.log`. Ruff PASS; Pyright 267 before and after, existing broad fixture diagnostics remain. No full remote suite or 13-suite profile was executed in this work unit; the final candidate still needs the selected profile.

Command from this worktree:

```sh
MASC_CONFIG_DIR="$PWD/config" PYTHONPATH="$PWD/test" python3 -c 'import test_tui_remote_workspace_history_pty as t; b="/Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-lane-editor-release-fixtures-main-20261004/_build/default/bin/masc_tui.exe"; t.scoped_roster_authority(b); print("foreign C / Board refusal: PASS",flush=True); t.scoped_roster_authority(b,matching_c=True); print("matching C / late B refusal: PASS",flush=True)'
```

All raw checker/execution logs are copied byte-for-byte, including EOF blank lines. Evidence whitespace warnings are not removed by normalizing raw logs.
