# Before the navigation output contract

An isolated native Firefox + Keeper run completed the three-channel fixture on
2026-09-12. The native TUI stayed open and followed the current channel region
map without input after its initial context copy.

`before.json` retains the observed binary identities, all 15 model tool calls,
operation outcome and owned-process cleanup. The new composition was not
available: `keeper_tool_search` failed once, then ordinary BrowserGoto/BrowserRead
calls completed the request. This is failure and recovery evidence, not a
successful composition or faster-collection result. Source inspection identified
BrowserGoto's opaque output contract as the catalog validation blocker.

The TUI audit found all three current channel URL/heading pairs in 149 complete
PTY frames. `tui-gamma.png` replays the captured native PTY in xterm; it is not a
physical-terminal screenshot. `firefox-final.png` is the actual isolated Firefox
screenshot. This proves current region-map following, not shared message-body
selection. No live Slack session was accessed.

The fixture and full co-viewing baseline/candidate experiments are in
[the persistent follow evidence](https://github.com/jeong-sik/masc/blob/6e9fc8a7318cb24a2d933836d2449653abb6f225/docs/evidence/browser-handoff-20260912/persistent-follow/README.md)
on PR #35391. The current candidate still needs compiled tests and a successful
composition run with the matching server binary.
