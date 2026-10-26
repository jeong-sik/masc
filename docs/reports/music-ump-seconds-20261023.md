# Source-relative seconds for native UMP experiments

The native UMP editor accepts decimal seconds alongside exact host ticks.
`:at-seconds`, `:shift-seconds`, `:note-seconds OFF_ID START END` and
`:duration-seconds OFF_ID S` feed the existing native time overlay and history.
Inputs are parsed as integer rationals, rounded once to nearest native ticks
with exact half ties away from zero, and checked against UInt64 endpoints.

Source zero comes from the asset's original clock span before overlays. Moving
an event into pre-roll does not move that zero for subsequent edits. Reimporting
an authored export creates a new source with its declared span; prior editor
history and earliest recorded provenance are distinct. The list displays
approximate relative seconds and `*` for authored time. Read-only `:clock`
returns exact authored host time, original source-event time and source zero.

Source head: `b2963400bba364d1e91a4ba932fe48f2838093ef` over time-parent
`0bdba486b5d8e862d865262ae724ca43ce7984f2`. The 118-test Node run used
`d5d56535a76c30f2d5386168ed49ba58288c51d5`; the two following product-label
lines clarified original versus recorded time without changing decision logic.

- 118 Node checks passed, including decimal/native-boundary refusal, stable
  source zero, exact tick quantization, explicit release matching, mixed
  pitch/value/time history, actual Worker/native-plan preparation and portable
  reopen after the former project was removed.
- An independent reviewer compared a frozen Node helper with a Python Fraction
  oracle for 2,496 inputs over six clock ratios, including signed half ties,
  large decimals and endpoint refusal. No new P0–P2 was found in the full source
  scope; source and response reviews remain separate from formal PR approval.
- A real source TUI child imported a synthetic take, entered negative pre-roll,
  authored later seconds relative to the original zero, edited an explicit note
  pair and expression time, used history, exported a new variant, placed/saved
  it, reopened the arrangement and reproduced six identical export files. The
  final attack/expression/release offsets were 5,400,000 / 7,800,000 / 14,400,000
  host ticks relative to the original source zero. Original raw UMP, WAV, audio
  blocks and source asset were retained.

[Receipt](../evidence/2026-10-23-ump-seconds/receipt.json) and
[source TUI verification](../evidence/2026-10-23-ump-seconds/source-tui-verification.json).

The TUI journey did not request playback. This layer's checks do not claim an
installed seconds-capable viewer, new native device delivery, USB/audio latency,
receive timestamp accuracy or sample alignment. The underlying host-time layer's
focused CoreMIDI evidence is separate. No Dune/full build or CI was run.
Tempo/beat ergonomics, automatic voice/gesture grouping, embedded clocks,
message insertion/removal, raw practice editing and MIDI2 Clip import remain in
#44748; the overall sequencer goal remains open.
