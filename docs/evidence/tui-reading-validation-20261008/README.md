# Local execution verification of the reading stack

The operator explicitly allowed this task's minimal local TUI build and related
PTY checks on 2026-10-08. The application source was frozen at
`22b0cf94cb588eca4ff1e169dcffd6a7b6d11f28` (#41685 → #41703 → #41712 → #41723).

`opam exec -- dune build --root . bin/masc_tui.exe` exited 0 with OCaml 5.5.1 on
macOS ARM64. The executable's `--build-commit` returns that exact SHA. Its SHA-256
is `aee76021d8473f7b64416f2659d12df51f9c8a85ad5799229c770cf813ef8694`.
No application source was changed or rebuilt during the scenario sweep.

## Evidence scope correction

The retained `chat-visibility-fixed` PASS belongs to an earlier fixture. Its
recorded fixture hash differs from the committed `test/tui_keyboard_chat.py`,
whose Escape scenario expects beta rather than alpha. It does not prove the
current scenario. Likewise, `region-layout-fixed` predates the corrected rail
check that derives the bottom from layout geometry. Both executions remain as
historical records; their current fixtures have not been rerun. The syntax
entries were refreshed by parsing the current files, which proves syntax only.

## Historical observed behavior

Passed actual PTY checks cover Info entry/manual/periodic refresh and stale
recovery, System identity at narrow widths, Keeper roster windows, Home
destinations and pane choice, Work selection/footer across resizing, primary
lists with and without color, chat origin modes and viewport clipping, Candle
currency, long Info/Channels metadata, chat command menu and status hierarchy,
and the earlier region sweep's Info frames and Gate clicks. Its rail check did
not detect a missing lower suffix.

The region sweep captured 44 frames across 80/100/109/110/157/158 columns.
The full remote workspace history scenario also passed, including held responses
and authority withdrawal/recovery. [Results](results.txt) and the
[execution manifest](executions.json) record 14 successful behavior invocations
plus one successful capture invocation, their original log hashes and compressed
logs. This historical count includes the two superseded fixture executions
identified above; it is not a count of current-fixture passes. Fixture syntax checks do not substitute for these executions.

## Repairs to the fixtures

- Skill ownership is checked from a completed screen's turn/request identity,
  aligned bracket and ordered body rows; metadata may occupy its own row.
- Detailed telemetry is explicitly opened. Command-menu selection is checked
  across the actual chat pane in both pinned-roster and default `NO_COLOR` views.
- Borderless rails now check the full extent through a bottom derived from
  the detail/chat layout; the recorded PTY predates that correction. Framed Info keeps strict
  corner checks. The region fixture ends its own observer stream in `finally`.
- Workspace tests await accepted state already on screen, retain the disabled
  draft when authority is unread, and preserve the runtime fixture before a
  schedule fixture overlays it. Confirmed workspace-change withdrawal and
  forbidden cross-workspace calls remain asserted.

Original failed logs remain in `/tmp/masc-tui-validation-20261008`; the final
manifest includes their hashes alongside corrected executions. These failures
were diagnosed from recorded terminal output and source before changing tests.
The equipped-portrait script also requires a separate native HTTP fixture; an
invocation without that argument did not execute it and does not count as a pass.

## Captures

Open [the preview](preview.html). The chat PNGs replay recorded local fixture
ANSI bytes through ttyd/xterm. The Keepers capture has conflicting execution
provenance: its archived STUDIO_CAPTURE records say CI, but its run metadata and
previous manifest said local. Its execution origin is unverified; the retained
image and ANSI hashes do not resolve that conflict. The replay tool now refuses
contradictory origins before writing any artifacts, and new primary-list captures
record the actual GitHub Actions context rather than an unconditional CI label. The capture tool verifies exact rows, columns and
screen text and checks that terminal pixels are not clipped before saving them.
Manifests keep binary, frame and screenshot hashes separate. The replay terminal
supplies its fonts; these are not screenshots of the installed application.

Independent evidence review caught an initial 120-column capture that returned
on its first paragraph before the frame ended. The capture now waits for the
visible cursor and `FRAME_END` and requires all 30 rows, the final paragraph,
composer, context and footer before recording either width. Both captures were
regenerated and verified. The superseded incomplete stream remains archived as
`INVALID_CAPTURE`, even though its original capture process exited zero.

These results establish the listed local macOS fixture behavior, not Linux CI,
release readiness, live Keeper continuity or deployment. The installed binary
was observed at `97980284b44f69215fc5d886ce70dfde098f6002` and was not replaced by
this older-base feature candidate. Broader Board/Usage/Workspace consistency
work remains tracked in the [ledger](../../design/tui/CONSISTENCY-PROGRESS.md).
