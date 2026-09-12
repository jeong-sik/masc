# Browser Lane TUI observation delivered to Keeper

The current instruction body was exercised with an actual TUI `y` copy from a
real Firefox page. The captured 535-byte JSON was delivered unchanged after
the natural request prefix through `masc_keeper_msg`. The model received that
same input, loaded the 12,380-byte instruction body, then made one scoped
BrowserRead with the observed URL/document/node and correctly answered Mina,
Tuesday, and accessibility review.

This final-body run uses SKILL.md from `c4cfc5369c`: 12,612 file bytes,
12,380 body bytes. Its delivered hash and subsequent BrowserRead call ID join
to an activation with `invocation.kind=instruction`. The response contains
only the selected Alpha article, excluding Beta and the sidebar.

## Current-body evidence

- [clipboard-run.json](clipboard-run.json): actual user input, source/runtime
  identities, tool calls and outputs, answer, activation and cleanup receipts.
- [clipboard-context.json](clipboard-context.json) and
  [clipboard-osc52.bin](clipboard-osc52.bin): captured payload and original
  terminal clipboard sequence. Decoding the sequence yields the exact payload;
  the payload is the unchanged suffix of the recorded model user message.
- [clipboard-tui.png](clipboard-tui.png): **replay of recorded PTY output at
  130 columns × 35 rows**, showing Alpha selected before copying.
  [clipboard-tui.pty](clipboard-tui.pty) contains the rendering up to the copy;
  the following OSC52 sequence is retained separately above.
- [clipboard-firefox.png](clipboard-firefox.png): actual Firefox screenshot
  from the same run. The observer capture receipt in clipboard-run.json ties
  its URL/tab to the copied observation. Screenshot and browser setup calls
  are excluded from Keeper call counts.
- [fixture.html](fixture.html): complete synthetic page used in the runs.

The TUI artifact was built from source `ba6b3a73e9` (CI run 34689504282, artifact
10297022201); its TUI source files are unchanged through `c4cfc5369c`. The
measured server is `d5fd7f3453`, with executable SHA-256 recorded in the JSON.
The candidate instruction package was copied only to the experiment's own
scratch skill source. The experiment used its own skill source and a fresh browser profile.
The Keeper shutdown finalized and the owned TUI/server/driver exited.

## Earlier comparison

The original comparison remains in [keeper-pair.json](keeper-pair.json).
These are three individual observations on fresh Keepers, not a controlled
benchmark or a general performance guarantee.

| Observed instruction | Served body | Keeper BrowserRead calls | Total Keeper tool calls |
|---|---:|---:|---:|
| Original `637efb0f25` | 16,908 bytes, rejected | 5 | 6 |
| Lazy split `869a35889a` | 11,698 bytes, delivered | 1 | 2 |
| Current guards `c4cfc5369c`, actual TUI copy | 12,380 bytes, delivered | 1 | 2 |

The original run tried regions, whole-page text, unsupported scoped elements,
whole-page elements, then scoped scene. Both later runs loaded the instruction
and directly read the selected article. All eventually returned the correct
owner and decision. The first pair used a constructed TUI-shaped payload and
server `d568ba7ffc`; it is historical evidence, not the current-body delivery
proof. Its [Firefox image](firefox-after.png) and
[capture receipt](firefox-after.json) are retained. Its before shutdown terminal
record was observed but was not preserved before startup pruned it; admission
alone is not presented as shutdown proof.

## Repetition and limits

The subsequent [three-channel experiment](three-channels/README.md) exercises
two lazily loaded instruction Skills and collection across three separate pages.
It records 12 tool calls, 125.647 seconds to observed completion, and the limits
of both the answer and simultaneous TUI following. It is a separate observation,
not a matched performance comparison with the single-page runs above.

Use a separate initialized scratch workspace, a configured model, a fresh
Firefox session serving the fixture, and the candidate instruction package.
Select Alpha in the TUI region view and capture its actual `y` output. Send
the natural request plus those exact bytes to a fresh Keeper whose profile
makes browser-lanes eligible. Record model input, operation, final answer,
tool I/O and activation ledger before closing owned resources. Verify the
scope and returned content, not only the operation's terminal status.

This proves TUI OSC52 output → masc_keeper_msg → instruction delivery → scoped
BrowserRead. It does not exercise OS clipboard readback or pasting into the
TUI chat composer. Each run used one synthetic page; real target channels and
site-specific collection remain unmeasured. The native screenshot shows all
articles together: scope filters scene output, not browser paint.
