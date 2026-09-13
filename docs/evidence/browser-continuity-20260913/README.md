# Browser continuity: live recovery and shared viewport verification

Native source `5334be62fca7e70350cff7e36899ef24f27230dc` completed a natural three-channel request despite three composition read failures, and a separate real TUI/Firefox trial verified automatic screenshot updates and shared-tab navigation. The original failed source `0e06ee97194d721b87d8ef7c7dfb7ac5e1765b8c` trials remain intact. Slack was not accessed.

## Verified follow-up trials

| Trial | Recorded result | Practical limit |
| --- | --- | --- |
| Live Keeper + Firefox extension/native host + persistent TUI | 3 channels, 9 outer calls, 3 failed compositions followed by 3 successful reads, 0 repeated navigations | Continuity works; immediate composition reads still fail, so this is not the shortest route |
| Native TUI + compiled MASC + automation Firefox | Link click, trusted drag, pane scroll; automatic PNG change; external navigation followed; next scroll uses new document | Trusted drag is automation-only; this trial has no Keeper/model |
| CI native TUI PTY scenario | Automatic refresh, same-tab navigation, drag ownership and dismissed-overlay regression passed | Synthetic HTTP responses in PTY regression; separate real Firefox trial above |
| Official-client materialized bundle CI | All 102 dispatcher tests, 4 retained-observation tests and 2 evidence tests passed | Deterministic injected failure, distinct from the naturally occurring Firefox errors below |

`after-read-recovery/` is operation `kmsg-209e8a70ec6f465214e511ae2393b3cf`, trace `trace-1789262171956-00000`. The Keeper received the actual TUI OSC52 region context and loaded the binary-exported native Skill packages. Each observed anchor was followed once. Each immediate content read failed with `Missing host permission for the tab`; the Keeper retained the completed navigation receipt and issued only a new `BrowserRead` with the same client/tab and `navigationSource`. All three reads succeeded in the same turn. The final answer distinguished current decisions from superseded/sidebar text, explicit owners from message authors, and visible history from unobserved history. See [answer.md](after-read-recovery/answer.md).

The recovered run returned 35,711 raw UTF-8 outer-result bytes in 50.179 observed seconds. These are single-run measurements, not a latency or provider-token improvement claim. The shorter browser Skill body was exactly 6,317 returned UTF-8 bytes. Four delivered scene JSON slices match retained blob bytes. The native TUI followed Alpha, Beta and Gamma across 59 complete frames, without operator input during the turn. The offline audit checks archived prefix/record identities; the channel PNGs were produced by the separate terminal replay procedure in the archived TUI audit script.

`after-viewport/` records the actual PNG payloads placed by the native TUI. The immediate scroll PNG was still identical to the drag PNG; one subsequent cadence capture changed it to the scrolled page without another input. A separate owned actor then navigated the same tab while the TUI viewport stayed open. The TUI displayed the new page and its next scroll used that page's URL/document. The separately recorded stale-viewport probe was refused with the exact URL guard error and left the pane at zero. This HTTP route does not expose effect disposition, so the archive does not claim wire-level pre-effect classification for that probe. Exactly four successful TUI interactions are recorded, separate from the external navigation and failed probe.

Both new trials closed their owned Firefox session, server and driver; the native TUI exited zero. No operator runtime restart or deployment is claimed.

## Remaining shortest-path gap

The read failure now reaches the model without terminating its turn, but the extension still attempts dynamic injection while a followed document is being replaced. Mozilla documents that navigation can produce the same generic host-permission error as actual missing permission ([Bug 2047009](https://bugzilla.mozilla.org/show_bug.cgi?id=2047009)). That is consistent with this trace; the error string alone cannot establish the cause or authorize retries. The next improvement needs a document lifecycle boundary while preserving the existing document-end read behavior, which can expose visible content before slow resources finish. Waiting for full page load or retrying based on the error string would not resolve that requirement.

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

`candidate.json` identifies measured source `5334be62fca7e70350cff7e36899ef24f27230dc`. Native run [34719307922](https://github.com/jeong-sik/masc/actions/runs/34719307922) passed; its exported bundle and all three binary hashes are included in each trial. TUI focused CI passed at prior source `20f45f0119ad59f96b9ea70876ef3990b79917e2` in run34718636492. Recovery CI passed at product head `ea4b446430dc6247dd442e6afc589f85f6e90785` in run34719306501. The measured source includes both changes. #35703 merged as `6d6c1b61cd5ce4e7ec14f4ee9a04051fb1f7d6c3`; viewport PRs #35704 and #35708 remain separate delivery state. The ordinary required check failure was an existing PTY observation race addressed in #35713, distinct from the focused browser tests.

The earlier combined candidate `b079feb43d99827daebfd104b27ad8fb283635ed` was superseded after the read-recovery Test run exposed a partial-application compiler error. `compiler-error.txt` preserves the diagnostic: the new optional receipt callback was still open at the async observer call site. Commit `00e8dbb0ba` explicitly closes that optional argument in both nontracking observer call sites. The old native and focused jobs were cancelled; the ledger retains their handles and the replacement dispatches. A cancellation is not a passing build.

Run `python3 docs/evidence/browser-continuity-20260913/audit.py`. This offline audit cross-checks receipt/event/turn identities and exact archived image bytes. It does not launch Firefox, rerender the terminal, or assert a comparative latency or provider-token improvement.
