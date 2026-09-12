# Persistent Browser Lane following

The earlier three-channel experiment closed the TUI after copying context. This
experiment keeps the same native TUI process open throughout the Keeper turn.
Only the isolated Keeper navigates the synthetic website after the OSC52 copy.

## Baseline

`before/run.json` records source `39ab9c606f9120d3439ea4792d73f589558e9661`,
native TUI SHA256
`df30addff6cb202469d663baf88643727b0ca4c49c2917a7b60516f0e7b9b6d6`, and the
actual TUI clipboard bytes delivered to the Keeper's user message. The server,
browser, instruction revision and model are recorded independently.

The Keeper loaded two instructions, made three BrowserGoto and seven BrowserRead
calls, and returned after 131.065 observed seconds with zero tool errors. The
final Firefox screenshot shows Gamma. The same TUI process remained alive,
rendered 136 complete frames, and still displayed Overview and `index.html`.

The replay audit checks a page's **current URL and channel-specific heading
together**. Merely finding Alpha, Beta or Gamma in the shared navigation is
insufficient. None of the three current page pairs appeared in the baseline.
`before/tui-final.png` is a replay of native PTY output;
`before/firefox-gamma.png` is an actual Firefox screenshot.

The baseline harness recorded process lifetime and terminal byte-arrival times.
Its no-post-copy-input claim comes from harness source inspection, not an input
event ledger; the subsequent harness explicitly records input writes and rejects
capture-thread errors. Byte-arrival timestamps are not browser navigation times.
All owned processes exited, and Keeper shutdown reached its finalized state.

## Candidate

`after/run.json` records source `a3ebdbc879d994349bd0a5d35f351c9fead33b4e`
from PR #35470, native TUI SHA256
`1861debe1a6249453c7e2b57efeff44c5f37475b78280a88b7583ec2cb97e778`.
The exact source passed the four PR checks and macOS native build. Its isolated
native PTY scenario also passed same-page selection/scope retention, repeated
input during a held read, replacement-document regions, and fresh text reads.

During the real Firefox/Keeper experiment, the same TUI process stayed open and
rendered all three current URL plus channel heading pairs. `tui-alpha.png`,
`tui-beta.png` and `tui-gamma.png` replay those measured frames. The TUI remained
in the region-map view selected by the operator; it did **not** mirror the
message-body scope that the Keeper read. Four input events were recorded, all
before or during the initial OSC52 copy. None followed the copy. Capture reported
no errors, and all owned processes exited after the Keeper completed.

| Observation | Before | Candidate |
| --- | --- | --- |
| Current channel URL + heading pairs rendered | 0/3 | 3/3 |
| Complete native PTY frames | 136 | 108 |
| Keeper tool calls / errors | 12 / 0 | 12 / 0 |
| Observed completion time | 131.065 s | 100.509 s |

Completion time includes model work, the 5-second polling cadence and
status-request latency. One run per candidate, with the same tool count, does
not establish faster collection or attribute timing differences to TUI changes.
The later raw-text navigation scroll fix and main merges are outside this
binary's evidence. This is synthetic data; Slack remains outside the experiment.
