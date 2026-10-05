## Why

v0.50.0 RC run `37275511275` job `111651580024` (behavior / test suite) fails with `[test-suite] FAIL - dune exited 1`. Two PTY expectations are stale against current `main`; no product code is wrong.

## What changed

`test/test_tui_keyboard_overview_pty.py` — `first_use_frames`
The Home approvals row now names each list that was not read:
`Approvals and questions: confirm queue not fully read; held calls not fully read; Gate queue not fully read; questions not fully read`
(`bin/masc_tui_home.ml`, `source_notes`). The old needle `Approvals and questions: not fully read` no longer exists. The wait now uses the real text `Approvals and questions: confirm queue not fully read`, which fits at both 80 and 140 columns. The assertion's intent (an unread briefing shows the not-fully-read note instead of claiming nothing is waiting) is unchanged.

`test/tui_keyboard_chat.py` — `chat_visibility_modes_interaction`
Leaving a chat returns to the Keepers list with the chat target selected. Message navigation follows its explicit target (`bin/masc_tui_keeper_selection.ml`, `Message_keeper` reindexes to the target; documented by `test/test_tui_keeper_selection.ml` "explicit target reindexes even if absent from the old roster", introduced in #40647). The scenario opened alpha's chat from a beta cursor, so after Esc the roster cursor is alpha. The final wait now expects `keeper_row_selected(b"alpha")`; the intent (Esc returns to the Keepers list) is unchanged.

No product code changed.

## Verification (this head)

Head: `a5d623ee3171f7c4e30446831dc865f86c8d9f2c` (base `origin/main` `6a9b9ac462159cf49603ff772582145ea4a569ec`)

```
$ dune build bin/masc_tui.exe
build_exit=0

$ dune build @runtest-test_tui_keyboard_general_pty @runtest-test_tui_keyboard_overview_pty
dune_exit=0
tui keyboard general PTY regression: PASS
tui keyboard overview PTY regression: PASS
```

Direct runs (same commands the dune aliases issue):

```
$ python3 test_tui_keyboard_general_pty.py ../_build/default/bin/masc_tui.exe
exit=0  -> tui keyboard general PTY regression: PASS

$ python3 test_tui_keyboard_overview_pty.py ../_build/default/bin/masc_tui.exe
exit=0  -> tui keyboard overview PTY regression: PASS
```

Before the change, both failed on this head with the exact RC errors:
- `test_tui_keyboard_overview_pty.py:165` timed out waiting for `b'Approvals and questions: not fully read'`
- `tui_keyboard_chat.py:2095` timed out waiting for `keeper_row_selected(b"beta")` (first drawn at offset 19317, none after the wait began)

## Scope

Only the two test files. No timeout was widened and no assertion was deleted.

— indie-geek-blue
