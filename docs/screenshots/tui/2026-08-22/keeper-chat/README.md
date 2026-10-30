# TUI Keeper chat runtime evidence — 2026-08-22

These screenshots come from the actual `masc_tui.exe` built from an immutable
Git archive at `43270efe690e2d0bc659aed117d5517354993e70` for PR #29500,
stacked on the merged production hardening from PR #29499. Each scenario used an
isolated temporary workspace and deterministic local HTTP fixture. The TUI ran
in a real PTY through ttyd and rendered in Chromium.

- Captured: `2026-08-22T12:15:56.524Z`–`2026-08-22T12:23:40.772Z`
  (`21:15:56`–`21:23:40 KST`)
- Merged production hardening SHA: `b0f56b0e2d99a2f752b76240417c5b1f1016d67e`
- Exact capture source SHA: `43270efe690e2d0bc659aed117d5517354993e70`
- Evidence asset commit SHA: `9167e2a3363584daccd0b539142119ef07dd741b`
- Immutable source archive SHA-256:
  `149af09aa88bb9bd0ba024fa15437151844fe673076a17a3695a58b61159e19e`
- Executable: `39,805,744` bytes, SHA-256
  `fc4d2bc83580fb832ced4cf47434235956dafede6ae7d765da506fc0caf70c71`
- Capture script SHA-256:
  `2fbaa2c8c70c5f1328140ad5e399f108cf85ecaa32e9a3358a8e3f6f61fd2451`
- Raw evidence SHA-256:
  `6f438fdf9e06a17bdbfd1e36db614e48a70a1001a8daf1de8a6db705d00bfa35`
- Fresh external build: `176.733s`, return code `0`
- Focused source verification: projection `23/23`, recovery `33/33`, TUI HTTP
  AST `11/11`, message layout `11/11`, render schedule `9/9`, operation store
  `9/9`
- CI target audit: `393` declared targets; unwired baseline `512`
- Terminal: `99 × 30`, plus compact `99 × 7`; screenshots are `834 × 480`
  pixels (`834 × 112` compact), device scale factor `1`
- Renderer: ttyd `1.7.7-unknown`, DOM renderer, xterm Unicode `11`, Playwright
  `1.59.0`, Chromium `147.0.7727.15`, Menlo `14px`
- Every capture asserts that ttyd's temporary dimension overlay is absent.
- Post-capture changes: no DOM replacement, redaction, AI generation, or image
  editing; all names, ports, request IDs, replies, and messages are synthetic.
- Machine-readable DOM text, request/response bodies and hashes, cursor
  positions, timings, binary identity, and PNG hashes:
  [evidence.json](evidence.json)

## Captures

| # | Observed behavior | Interaction or state change | Screenshot |
|---:|---|---|---|
| 1 | A `99 × 7` terminal shows the resize gate and hides the cursor. | Resize from `99 × 30` to `99 × 7`; hidden input is rejected. | [PNG](01-chat-tiny-resize-gate.png) |
| 2 | A long grapheme-rich draft keeps its final cells and cursor inside the border. | Restore `99 × 30`; enter a clipped draft ending in hearts and `-TAIL`. | [PNG](02-chat-long-tail.png) |
| 3 | Backspace removes one visible scalar without moving outside the viewport. | Backspace once at the clipped tail. | [PNG](03-chat-long-tail-backspace.png) |
| 4 | Mixed UTF-8 input renders with the xterm Unicode-11 cursor at `(25, 24)`. | Enter `Aé한🙂👍🏽🇰🇷❤️-proof`. | [PNG](04-chat-unicode-draft.png) |
| 5 | Submission does not block input; a second draft stays editable while the POST is held. | Serialize the dispatch lock, enter, then type `draft-during-send`. | [PNG](05-chat-inflight-responsive.png) |
| 6 | The reply uses the same shortened request ID and the in-flight draft remains. | Release the successful stream; verify done ACK and lock release. | [PNG](06-chat-success-correlated.png) |
| 7 | EOF after acceptance becomes `outcome unverified`; a fresh-ID resend is blocked. | End the accepted stream before a terminal event. | [PNG](07-chat-outcome-unverified.png) |
| 8 | Restart recovery polls that exact accepted operation and blocks resend. | Hold Ctrl-R GET, stop the TUI, restart it, and hold its automatic GET. | [PNG](08-chat-restarted-reconciling.png) |
| 9 | A settled recovery clears the fence and re-enables send. | Release the second exact-operation GET. | [PNG](09-chat-reconciled.png) |
| 10 | Only a durable `Replayable` fence reissues the exact ID. | Start with a v3 Replayable fence and hold its serialized POST. | [PNG](10-chat-replayable-exact-replay.png) |
| 11 | A second TUI cannot claim a Prepared fence while another process holds the dispatch lock. | Hold the real `.dispatch.lock` in a separate process. | [PNG](11-chat-stale-prepared-blocked.png) |
| 12 | A stale observer cannot recreate a fence removed after the owner's definitive rejection. | Owner sends one POST and clears; observer presses Ctrl-R afterward. | [PNG](12-chat-stale-fence-not-recreated.png) |

## Measurements

- Resize restored the input cursor to `(6, 24)`. `👍🏽` moved it to `(10, 24)`;
  one scalar backspace moved it to `(8, 24)`. The clipped tail and its
  backspace state both remained at `(97, 24)`.
- The externally held dispatch lock produced its blocked UI in `24.615ms` and
  allowed `0` POSTs. After release, the exact POST arrived in `19.220ms` and
  the no-input `sending` frame appeared in `25.767ms`.
- The dispatch lock remained unavailable to a separate process while the HTTP
  response was pending. The draft appeared in `37.278ms`; the reply appeared
  `31.812ms` after release. The separate-process nonblocking probe completed
  `30.524ms` after the reply became visible and `28.693ms` after the `sending`
  indicator had cleared. These intervals prove release by the probe; neither
  is the exact lock-release latency.
- Ctrl-R reached the exact operation GET in `4.247ms` and the reconciling UI in
  `11.806ms`, with zero browser navigations. Restart reached the automatic
  exact GET in `242.882ms`; the settled result appeared `31.244ms` after
  release.
- A durable Replayable fence reached its exact-ID POST in `262.928ms`.
- In the two-TUI race, the observer showed the externally blocked Prepared
  state in `3356.525ms` with `0` POSTs. The owner's HTTP `403` rejection removed
  the fence in `52.544ms`, and it remained absent through a separate `500ms`
  stability observation. The stale observer re-enabled send in `41.309ms`;
  after another `350ms` observation the total remained exactly one POST.
- Across the four scenarios the fixture observed exactly four chat POSTs and
  two same-operation GETs. Every scenario recorded zero other POSTs, zero
  unexpected chat routes, and zero fixture errors.

The screenshots prove fixture-backed execution and terminal rendering for this
exact executable and viewport. They do not claim that either PR is deployed or
that a production API served the responses.

[근거] The immutable archive, executable, capture script, terminal DOM, raw
HTTP bodies, lock probes, timings, cursor positions, PNG dimensions, and every
SHA-256 value were checked during the exact-head capture on 2026-08-22 KST;
confidence High.
