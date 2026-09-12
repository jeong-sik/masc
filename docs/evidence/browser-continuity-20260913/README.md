# Browser continuity failures and follow-up verification

Two independent failures were observed with CI-built native source `0e06ee97194d721b87d8ef7c7dfb7ac5e1765b8c`. These are failed trials, including the one where all three browser effects completed. Slack was not accessed.

## Completed navigation, failed read, terminated Keeper turn

`before-read-failure/` records a natural three-channel request using the native TUI's copied region context, an isolated live Firefox extension/native host, and the exported progressive browser Skill. The Keeper loaded both instruction Skills, read the selected region and chose an observed anchor. The composition's navigation completed; its following read returned `Missing host permission for the tab`. The aggregate `proven_post_effect` failure terminated the provider turn.

- Operation: `kmsg-8e1f8b083e7ec2c308711fa23a989de6`, terminal `Failed`.
- Four outer calls, one failed composition, no successful composition; 13,761 raw UTF-8 result bytes.
- Both settled node receipts are present. `raw-tool-results.json` preserves actual tool completion events, joined by `tool_use_id` to durable receipts and the typed turn's execution IDs.
- `firefox-final.png` shows Alpha loaded after the failed read. This demonstrates the navigation result; it does not establish a successful channel extraction or prove why Firefox rejected the intermediate read.
- The terminal assistant slot contains a runtime error, not a completed answer. The audit preserves it as `terminal_text` and leaves `answer` null.

[PR #35703](https://github.com/jeong-sik/masc/pull/35703) permits a later read in the same provider turn after fully recorded ordinary read failure. It preserves failure/effect evidence and does not automatically replay navigation or resume a graph after provider restart.

## Completed TUI gestures, stale screenshot

`before-stale-viewport/` records actual native TUI mouse/key input forwarded unchanged to compiled MASC and automation Firefox. There is no Keeper/model in this experiment. The recorder omits authorization headers.

Exactly one `click_at`, one trusted `drag` and one `scroll_at` completed. Independent scene observations show the opened link, trusted drag handlers and pane scroll of 120 CSS pixels. However, the immediately returned scroll PNG is byte-identical to the preceding drag PNG. Those exact PNG bytes occur in the TUI's Kitty image placements in the retained PTY.

The experiment also failed cleanup: the original wait did not establish a TUI exit status. The archive keeps that failure; a later `ps` observation found the PID absent and does not turn the missing exit status into zero. The revised probe drains the PTY while waiting for shutdown.

[PR #35704](https://github.com/jeong-sik/masc/pull/35704) adds screenshot reads on the existing UI cadence. Background captures yield to gestures, and stale results cannot replace a newer image or reopen an overlay dismissed while the operator stays in Browser Lane. The new PTY regression on the older native binary reaches the initial image, then fails specifically waiting for `AUTOMATIC FRAME`; `before-native-pty-test.log` retains that negative control.

## Candidate and limits

`candidate.json` identifies combined source `b079feb43d99827daebfd104b27ad8fb283635ed`, including the merged progressive Skill, read recovery and viewport cadence. Native CI and focused tests were dispatched; this archive currently contains only the preceding failure evidence. It does not claim that the combined candidate passed a live trial or was deployed to the operator's local runtime.

Run `python3 docs/evidence/browser-continuity-20260913/audit.py`. This offline audit cross-checks receipt/event/turn identities and exact archived image bytes. It does not launch Firefox, rerender the terminal, or assert a comparative latency or provider-token improvement.
