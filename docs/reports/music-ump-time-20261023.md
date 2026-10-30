# Native UMP event time and explicit note length editing

The native UMP editor now authors message times without converting the source to
MIDI1 or a PPQ note projection. Original packet:word identities survive derived
packet splitting and time sorting. Pitch/value/time overlays preserve each other
through history, variants, playback preparation, portable save/reopen and export.

`:events` selects any original message. `:time HOST_TICKS` and
`:shift-time SIGNED_TICKS` author exact UInt64 host-clock times. In the MIDI2
note view, `:note-time OFF_ID START_HOST END_HOST` or
`:duration-ticks OFF_ID TICKS` edits an explicitly chosen release with the same
source/group/channel/Note Index. No repeated-note pairing or controller ownership
is inferred; pedals, expression and WAV do not automatically follow a note.

The owned derived snapshot marks changed times as authored and retains recorded
time/origin provenance. Its manifest describes the derived packet count and
explicit source span. Moving events inward retains the old horizon as silence;
new times can extend either edge. Standalone inspection/audition and arrangement
preparation consume the same validated span, including after export/reimport.
Original asset parts, manifest and bounds remain under their recorded hashes.

Source execution head: `9c17b847250dd8c7db6e79a43ccfadf979e2c297`.
Source base: `f777165d3306d9173235349d4454b0ffacd83212` (the expression
parent, still unmerged when this work began). Documentation-only head after these
checks: `54c64fa3925e3699c65e9e0e10ebeb83621c9f0d`.
After the expression parent merged, all 17 changed source/test files were byte
identical at rebased source `03f47cd982563299beeb4835a91a6bf9108fc811`.
The native time/receive/cancel probe passed again at docs head
`8e32078577458b60fa2681e9b749081e25e6a087`; the public native receipt records
that later execution.

- Node: 112 passed, zero failed, including real Worker preparation, inward-only
  horizon preservation, mixed time/value/pitch history, invalid candidate
  refusal, export/reimport and portable reopen with the former project removed.
- Focused native decisions passed after repairing five helper files' direct
  UmpPacket initializer arguments. The four-source Swift/CoreMIDI probe also
  passed an independent authored-tick oracle and actual two-destination native
  MIDI2 full/cancel receive-word and resource-retirement checks. This does not
  claim all other native helper suites were rebuilt or receive host timestamps
  measured.
- Actual source TUI requests imported a synthetic five-packet take, edited
  expressions/pitch and an explicit attack/release plus an expression timestamp,
  exported nine derived messages, returned a separate variant, placed/saved it,
  reopened the arrangement and reexported six byte-identical files. The original
  asset, raw UMP, WAV and audio blocks were preserved. No TUI playback was
  requested, and no terminal wording/layout was asserted.
- Independent initial review found two P2 defects: Swift constructor arguments
  and a shortened standalone horizon after inward edits. Both were repaired;
  the independent actual Worker counterexample now reports matching standalone
  and arrangement duration. Response review read the fix and direct consumers.

[Receipt](../evidence/2026-10-23-ump-time/receipt.json),
[native receive evidence](../evidence/2026-10-23-ump-time/native-wire.json),
[source TUI file verification](../evidence/2026-10-23-ump-time/source-tui-verification.json).

These are source/focused-protocol observations, not default installed Ghostty,
USB instrument, acoustic latency or sample alignment proof. JR/delta-clock
sources still need an embedded-clock editor. Automatic voice/gesture grouping,
message insertion/removal, raw practice editing and MIDI2 Clip import remain
part of #44748; the overall sequencer goal remains open.
