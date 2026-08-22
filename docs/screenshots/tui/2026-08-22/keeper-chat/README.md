# TUI Keeper chat runtime evidence — 2026-08-22

These screenshots come from the actual `masc_tui.exe` built from an immutable
Git archive at `b281875e9aed5000cb6cf8b113a3a1b5e5088881` for PR #29500,
stacked on the production hardening in PR #29499. Each scenario used an
isolated temporary workspace and deterministic local HTTP fixture. The TUI ran
in a real PTY through ttyd and rendered in Chromium.

- Captured: `2026-08-22T11:22:00.074Z`–`2026-08-22T11:25:18.228Z`
  (`20:22:00`–`20:25:18 KST`)
- Production hardening SHA: `464b8753ba3bc4a74f1c4c0cba5f33d7c830944f`
- Exact capture source SHA: `b281875e9aed5000cb6cf8b113a3a1b5e5088881`
- Evidence asset commit SHA: `592416491115d29a403a97c84628ec2b7bb821d0`
- Immutable source archive SHA-256:
  `6fd58f63ceb038245939b4fa11b28c646999efc9fb12cdc505f0e6349574c90a`
- Executable: `39,805,744` bytes, SHA-256
  `70a0e53404ebe47c22fde0f4e60a0363ca2aeb089c61771c47d882ece35dab30`
- Capture script SHA-256:
  `8a36525044cfe44ff6f28a71fc07008669154957a42769c5af1f63f4da6a957d`
- Raw evidence SHA-256:
  `38120d96aa14a4c87e494d032046a5d18ca80a6952c8365290a8e085158fe3f9`
- Fresh external build: `164.542s`, return code `0`
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
- The externally held dispatch lock produced its blocked UI in `7.688ms` and
  allowed `0` POSTs. After release, the exact POST arrived in `18.514ms` and
  the no-input `sending` frame appeared in `24.283ms`.
- The dispatch lock remained unavailable to a separate process while the HTTP
  response was pending. The draft appeared in `37.254ms`; the reply appeared
  `32.990ms` after release. A separate-process nonblocking probe succeeded
  within `27.657ms` after the reply became visible, proving that the done ACK
  had released the lock by that probe; it is not the exact release latency.
- Ctrl-R reached the exact operation GET in `4.425ms` and the reconciling UI in
  `7.233ms`, with zero browser navigations. Restart reached the automatic
  exact GET in `241.336ms`; the settled result appeared `23.463ms` after
  release.
- A durable Replayable fence reached its exact-ID POST in `256.430ms`.
- In the two-TUI race, the observer showed the externally blocked Prepared
  state in `3314.071ms` with `0` POSTs. The owner's HTTP `403` rejection removed
  the fence in `55.137ms`, and it remained absent through a separate `500ms`
  stability observation. The stale observer re-enabled send in `44.738ms`;
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
