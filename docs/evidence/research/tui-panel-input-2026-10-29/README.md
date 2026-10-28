# Panel input and information observation

Observed 2026-10-29 KST. The [manifest](manifest.json) binds these original
terminal captures to source `0bf908eaf7de3a8a63d69a1bf3edfb635d5c4f16`,
the downloaded macOS arm64 executable and the synthetic fixture. This is a
real TUI in a private tmux session, with fabricated chat and a read-only
loopback server. It is not an installed production binary or a live Keeper.

Executable provenance: **Minimal manual checks**, run
[40705531014](https://github.com/jeong-sik/masc/actions/runs/40705531014),
workflow ref `main` / `d09ba9bf23bb384bda78dae8fbc4a4bd674bf7be`,
selected source `0bf908eaf7de3a8a63d69a1bf3edfb635d5c4f16`, conclusion
**success**. The binary's `--build-commit` matched the selected source. The
workflow's `detail-ownership` suites do not test Queue or these observations.

The unchanged [fixture](../tui-information-layers-2026-10-28/populated-fixture/fixture.py)
serves eight synthetic chat messages, 18 pending events, one running row and
one future schedule. Other reads return 503 and every POST returns 405.
HOME, workspace and executable search path were isolated; no real model was
called. The generation-mismatch footer is an expected fixture limitation.

Manual observations, without screen-text/layout pass-fail assertions:

| Sequence | Retained capture | Observed result |
| --- | --- | --- |
| Type `ORIGINAL-DRAFT`; Ctrl-X; bracketed paste `CONTEXT-PASTE-MARKER`; Esc | [before](context-before-paste.txt), [returned chat](chat-after-context-paste.txt) | The marker remains in the covered chat draft; the fixture rejects POSTs. |
| Context, hints off; `?` | [after question](context-after-question.txt) | Context stays open; its footer offers `?:help`. |
| `/about`, hints off; `?` | [before](about-before-question.txt), [after](about-after-question.txt) | About stays open; its footer offers `?:help`. |
| Open Queue at 120×36; resize to 80×24 | [120×36](queue-120x36.txt), [80×24](queue-80x24.txt) | All 18 pending-event rows are visible at 120×36; 11 at 80×24. Neither frame displays chat history. |
| Queue at 80×24; `?`; Esc | [Help](queue-help-80x24.txt), [return](queue-return-from-help-80x24.txt) | Help opens and Esc returns to Queue. |

The event count is an analyst's reading of these captures, not a test or a
performance measurement. The selected/read state, fixture and geometry must
match before comparing it with another observation. This is not evidence of
task completion time, user preference, arbitrary input timing, real IME,
server reordering or the corrected candidate's behavior.
Key sequences are manual observation notes, not a complete terminal event log.

Scratch observations remain under
`masc-tui-queue-research-20261028/artifacts/tui-observation-20261029`.
Two scratch images are deliberately omitted: `context-after-paste.png` was
misnamed and renamed `context-reopened-after-about.png`; it shows an empty
draft after a later operation. The paste finding uses the original text
captures above. An attempted Agenda capture showed the roster and does not
establish Agenda behavior.
