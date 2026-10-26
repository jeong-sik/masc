# Native MIDI2 per-note expression editing — 2026-10-23

Captured MIDI2 experiments can now change the recorded data values of registered
and assignable per-note controllers, per-note pitch bend and poly pressure.
The existing immutable UMP document and preparation path remain authoritative;
this does not convert the capture to MIDI1. The
[guide](../../tools/alphatex/UMP-SOURCE.md) explains the commands, and the
[receipt](../evidence/2026-10-23-ump-expression/receipt.json) records this
source execution's exact head/base, counts, received words and saved-file results.
Raw local orchestration logs are not bundled in this PR.

## Editing and persistence

Tab or `:expressions` selects the expression view; `:select-expression PACKET:WORD`
addresses an original message. `:value32 DECIMAL` replaces only its complete
32-bit data word, and `:reset-expression` removes only that expression patch.
The same source hash and original packet/message identity bind both note and
expression patches. Address words, note indices, controller indices, message
order, source/group/channel, original host ticks and timestamp-origin flags stay
fixed. A message is not reassigned to an inferred NoteOn owner. Management,
SysEx and other message classes stay unchanged. Invalid note or reserved address
bits refuse an expression target.

Notes and expressions retain each other's changes, share undo/redo and use the
same arrangement import, standalone/native playback preparation, portable save
and native bundle export. An expression-only source opens without a synthetic
note. Note commands refuse a hidden note target while the expression view is
selected; value commands likewise require the expression view.

## Executed checks

- Focused Node selection: 105 tests passed in the expression/source/capture/TUI
  controller/arrangement-editor files. The new Worker case follows expression
  editing through both playback plans and native export, removes the old source
  directory, then reopens the portable arrangement and compares all six export
  files. Literal expected words check all four message classes, full uint32
  endpoints/center, original addresses and unrelated data. Invalid candidates,
  mixed note/expression reset/history and expression-only sources are covered.
  Controller checks inspect requests, returned edits and lifecycle, without
  asserting terminal wording or layout.
- A focused Swift/CoreMIDI probe was compiled and run by
  `node tools/alphatex/native/test-edited-ump-wire.mjs`. Full playback and
  cancellation each created two owned private MIDI2 destination endpoints, one
  per source. Received full streams match 28 words for A and 4 for B. Explicit
  expression data are registered controller `0x7a000001`, assignable controller
  `0`, per-note bend `0x80000000` and poly pressure `0xffffffff`. Fractional
  absolute pitches, 16-bit velocities, original indices/releases and untouched
  pedal messages also match the literal oracle. Cancellation waits for attacks
  at both destinations, then checks the admitted prefix and note/pedal cleanup;
  timer, held state, port and client retire. No physical instrument or audio
  output is opened by this probe.
- A real source TUI imports a synthetic five-packet capture, changes four
  expression values plus a fractional NoteOn pitch, exports, returns a distinct
  arrangement variant, places it, saves, closes and reopens the saved document.
  Reopened native export matches all six files byte for byte. Original asset,
  WAV, clock and raw MIDI remain unchanged. Expected expression values are
  `4294967295`, `0`, `2147483648`, `305419896`; Pitch7.9 is `30976` (60.5).
  Undo/redo requests were sent in this terminal journey, but intermediate states
  were not separately snapshotted; their precise history behavior is covered by
  the focused editor tests rather than inferred from that command log.

The native receipt records actual received words, not device-receive host times.
Raw timestamp preservation is established by exact Worker/plan packet and export
comparisons, not a claim of sample-exact or physical synchronization. The source
TUI execution and temporary native probe do not prove an installed launcher,
physical USB behavior, acoustics, plugin expression support or Ghostty layout.
No local Dune/full build, CI dispatch or server replacement was performed.

## Remaining sequencer work

Native time/structure edits, insertion/removal of expression messages, raw
practice-take editing and MIDI2 Clip import remain under
[#44748](https://github.com/jeong-sik/masc/issues/44748). This layer edits existing
message values, preserving their address/lifetime semantics; it does not infer
sounding pitch from tuning or ownership of overlapping/detached voices.
