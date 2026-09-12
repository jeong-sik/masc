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

The automatic-follow implementation is PR #35470. Candidate compiled/native
verification and the corresponding persistent browser experiment are pending.
The baseline is not evidence that the candidate works or that channel collection
is faster. This is synthetic data; Slack remains outside this experiment.
