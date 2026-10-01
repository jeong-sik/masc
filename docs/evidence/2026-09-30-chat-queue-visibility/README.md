# Chat queue visibility

Patched execution follow-up: [2026-10-01 Queue/image build and PTY evidence](../2026-10-01-tui-queue-image/README.md). The observations below retain their original source/binary scope.

The isolated PTY reproduced the reported disappearance with the existing
installed TUI, version 0.49.0. Both the installed executable and the checkout's
existing executable had SHA-256
`0ba80256daabb703cdcfbed4097a31b0c5a2cb136a424d59015da1d919951f44`.
Its exact source commit was not verified.

- `local-waiting-120x40.*`: the first POST is held before acknowledgement;
  a second input is still local. The old Queue summary shows only that one.
- `server-waiting-120x40.*`: both inputs are accepted as Queued, execution
  remains held, and the Queue summary disappears. The remaining WAITING TO
  START row explicitly reports two server-queued messages.
- ANSI files preserve the captured output. PNGs render the recorded terminal
  text using Pillow; their colours are illustrative.

No production Keeper messages, interrupts, or settings changes were made.
The HTTP fixtures ran against a separate temporary workspace and PTY.

The final focused test is `test/test_tui_queue_visibility_pty.py`. It also
checks the newly identified gap before POST acknowledgement, so it can fail
earlier on the old executable than the initial capture-producing version.
The OCaml lifecycle test covers execution start, completion, failure,
continuation checkpoints, keeper scoping, and local/submitted overlap.

Initial implementation validation, before the review response below:

- Existing executable: FAIL reproduced and captured as above.
- Changed production OCaml module: `ocamlc` 5.5.1 isolated typecheck PASS,
  reusing existing build/installed dependency CMIs; no dependencies rebuilt.
- Changed OCaml files: parsing PASS.
- New Python scenario: syntax PASS.
- `git diff --check`: PASS.

The patched TUI has not been built or executed. New regression tests have not
yet run against it; no CI was dispatched. A Full CI build and the registered
focused PTY/lifecycle tests remain release validation under the repository's
execution protocol. These captures prove the old defect, not a repaired
production session.

The review response separates the aggregate pending count, confirmed Keeper
queue count, delivery checks, and local NEXT preview into individual activity
rows. The header reserves Ctrl-T before fitting auto-next; the renderer and
status-height budget still consume the same row projection. A request awaiting
its first receipt is labelled `awaiting receipt`; a reconnecting request is
labelled `rechecking delivery` even when an older receipt said Queued.

The focused PTY scenario now includes two accepted requests plus one local
request at 80 columns, verifies the local preview and Ctrl-T remain visible,
visits another Keeper while requests remain pending, and returns before
releasing the held control receipt. It also runs the existing reconnect
fixture with an explicit uncertainty assertion. Lifecycle coverage checks the
typed transition from awaiting receipt through reconciling and confirmed
queued to execution start.

For this response, three changed OCaml files passed parsing, three changed
Python files passed syntax checks, and `git diff --check` passed. The added
80-column, navigation and reconnect cases have not been executed against a
patched binary. The existing screenshots and ANSI files remain evidence of
the original defect only.
