# TUI Keeper chat screenshots — 2026-08-22

These screenshots come from the actual `masc_tui.exe` built from an immutable
Git archive at `526adab30607a259306331fbe1fbfd3950bc4f49` for PR #29317. Each
scenario used an isolated temporary workspace and deterministic local HTTP
fixture. The TUI ran in a real PTY through ttyd and rendered in Chromium.

- Captured: `2026-08-22T07:14:33.560Z`–`2026-08-22T07:17:53.817Z`
- PR: `#29317`
- Code source SHA: `526adab30607a259306331fbe1fbfd3950bc4f49`
- Evidence asset commit SHA: `6191fac6cb9dd38fb095d939164bdcd74a19d38a`
- Worktree before and after capture: clean at the exact code source SHA
- Source archive SHA-256:
  `e9d51e4fb89b9c45fee24415a51c1189eb89bc5e771f28ac8e12f21c7796b12f`
- Executable SHA-256:
  `7b0e754fe573e5e8353b9152445bef3739daa1c78869a89a41f87e75853081eb`
- The executable was rehashed after capture and then removed with its temporary
  build directory; its byte size was not recorded
- Capture script SHA-256:
  `91d67dfe63ffa1796f884d16a7f518c437065c06ddd640d0bfa6086d1ec0b63b`
- Build: `scripts/dune-local.sh build --build-dir <fresh-external-dir>
  bin/masc_tui.exe`; completed in `183.267s`
- Focused results: Keeper chat projection `22/22`, recovery `4/4`, message
  layout `11/11`, TUI HTTP AST `10/10`, executable build passed
- CI target audit: `388` declared targets; unwired baseline `513`
- Terminal: `99 columns × 30 rows`, plus the compact `99 × 7` case
- Screenshot: `834 × 480` pixels (`834 × 112` for compact), device scale
  factor `1`
- Renderer: ttyd `1.7.7-unknown` DOM renderer, active xterm Unicode version
  `11`, Playwright `1.59.0`, Chromium `147.0.7727.15`
- Terminal font: Menlo, `14px`
- Runtime settings: `TERM=xterm-256color`, `MASC_TUI_SYNC=off`, refresh `60s`
- Screenshot selector: `.xterm-screen`
- Post-capture changes: no DOM text replacement, redaction, AI generation, or
  image editing; all names, ports, request IDs, replies, and messages are
  synthetic fixture data
- Machine-readable hashes, assertions, and measurements:
  [evidence.json](evidence.json)

## Captures

| # | Observed behavior | Interaction or state change | Screenshot |
|---:|---|---|---|
| 1 | A `99 × 7` terminal shows the resize gate and hides the cursor. | Resize from `99 × 30` to `99 × 7` | [PNG](01-chat-tiny-resize-gate.png) |
| 2 | A long grapheme-rich draft keeps its final cells and cursor inside the right border. | Restore `99 × 30`, enter a long draft ending in hearts and `-TAIL` | [PNG](02-chat-long-tail.png) |
| 3 | Backspace removes one visible scalar without moving the cursor beyond the viewport. | Backspace once at the clipped tail | [PNG](03-chat-long-tail-backspace.png) |
| 4 | Mixed UTF-8 input renders with the xterm Unicode-11 cursor at zero-based `(25, 24)`. | Enter `Aé한🙂👍🏽🇰🇷❤️-29317` | [PNG](04-chat-unicode-draft.png) |
| 5 | Submission does not block input; a second draft remains editable while the POST is held. | Enter, then type `draft-during-send` before releasing the response | [PNG](05-chat-inflight-responsive.png) |
| 6 | The reply is correlated with the same shortened request ID and the in-flight draft remains. | Release the successful stream response | [PNG](06-chat-success-correlated.png) |
| 7 | EOF after accepted transport becomes `outcome unverified`; resend is blocked and Ctrl-R is offered. | End the accepted stream before a terminal event; capture before pressing Ctrl-R | [PNG](07-chat-outcome-unverified.png) |
| 8 | After process restart, the persisted fence automatically polls that exact operation and blocks resend. | Press Ctrl-R and hold the first exact GET; stop and restart the TUI; hold the automatic second GET | [PNG](08-chat-restarted-reconciling.png) |
| 9 | A settled recovery clears the fence, reports the transport-only result, and re-enables send. | Release the second exact-operation GET | [PNG](09-chat-reconciled.png) |

## Measurements

- Compact-to-full resize restored the cursor to zero-based `(6, 24)`.
- `👍🏽` moved the cursor from `(6, 24)` to `(10, 24)`; one scalar backspace
  moved it to `(8, 24)`.
- The clipped long tail and its backspace state both kept the cursor at
  zero-based `(97, 24)`, inside the `99`-column terminal.
- The Unicode draft became visible in `165.927ms` while the chat POST remained
  held. The reply appeared `44.182ms` after the fixture released the response.
- The successful scenario issued exactly one chat POST, no operation GET, and
  sent `38` UTF-8 bytes with SHA-256
  `bb687202b11b8eb885db3d4738a7a38bc3c5ecaccea5fd63c1b77a8fe85ceff1`.
- Ctrl-R reached the exact operation GET in `13.207ms` and the reconciling UI
  in `18.614ms`, with zero browser navigations.
- After restart, automatic recovery reached the second exact operation GET in
  `225.913ms`; the settled result became visible `86.127ms` after release.
- The recovery scenario issued exactly one chat POST and two GETs to the same
  synthetic operation path, with no unexpected chat routes or fixture errors.
The screenshots prove fixture-backed execution and terminal rendering for this
exact executable and viewport. Focused tests remain the behavior proof. This
does not claim that PR #29317 is deployed or that a production API served the
responses.

[근거] The exact source archive, executable, capture script, terminal buffer,
HTTP counts and paths, timings, cursor positions, PNG dimensions, and PNG
SHA-256 values were checked during the capture on 2026-08-22 KST; confidence
High.
