# Fractional project beats for native UMP experiments

The native UMP editor now accepts `:at-beats`, `:shift-beats`,
`:note-beats OFF_ID START END` and `:duration-beats OFF_ID B`. Beat input supports
decimals and exact signed fractions such as `1/3`. The arrangement passes its
opening tempo to the child editor; no default tempo is inferred. One beat is a
quarter note, independent of the meter denominator.

The existing project's exact binary64 tempo is converted to its rational value,
and authored beats convert directly to native host ticks with nearest-tick,
half-away rounding once. Source zero stays fixed across pre-roll edits. Existing
explicit release validation, immutable mixed pitch/value/time history and native
source identities remain authoritative. Tempo is editor context, not a new asset
field. Later project tempo changes leave authored capture times and WAV unchanged
and affect future beat inputs when the editor is reopened.

Execution source head is `0869ee0bd9d5835bda22db5829a2be7e44d4a668`, over seconds
parent `55fe8612167854e96938166d6e519701318fa44b`. Final reviewed source head
`8f9eb1e84450fb1cab94f73d89f0a0954a9887b6` adds only the controller test repair
described below; all production blobs are identical.

- Initial focused execution passed 107 tests before an error-label-only change.
- Initial broader execution passed 161/162. The existing mixed-controller test
  counted periodic `status` in its first three control requests. The failure is
  retained. The same source head passed 162/162 with test-file concurrency one.
- The final test repair excludes only `status` and compares the entire remaining
  control sequence, replacing the old first-three prefix. The mixed fixture now
  explicitly emits `status`. All 90 controller tests passed at the final test
  content; this is not a new final-head execution of all 162 tests.
- Independent Python Fraction reference probes passed 6,840 beat cases across
  six clocks and twelve binary64 tempos, including finite extremes, plus 2,496
  seconds regression cases after the shared rounding refactor. Source and
  response reviews found no new P0–P2; formal GitHub approval is separate.
- A real source TUI opened an arrangement at 137.1 BPM, edited negative pre-roll,
  an explicit attack/release pair and expression time with fractional beats,
  exported a separate variant, placed/saved it, closed/reopened and reproduced
  six byte-identical export files. Independent Fraction/file calculations checked
  all nine derived messages, four raw scalar edits, one Pitch7.9 edit and three
  timing edits, with original metadata, source asset and raw parts preserved.
  Final attack/expression offsets are both 5,251,641 ticks; the release offset is
  10,503,282 ticks. The original half-open source extent 12,000,101 remains even
  though the edited release moved inward. MIDI SHA256 is
  `41bfa00fa249b96b603ba00272436720e79a21f0c2e295d7e0317a9cc916c73a`.

[Receipt](../evidence/2026-10-23-ump-beats/receipt.json) and
[source TUI verification](../evidence/2026-10-23-ump-beats/source-tui-verification.json).

The TUI uses a synthetic take and did not request audition or capture. Negative
pre-roll and undo/redo requests are recorded, but intermediate snapshots were
not independently captured. No beat-capable installed launcher, new native build
or device delivery, physical MIDI/audio latency, receive timestamp accuracy,
sample alignment, Dune/full build, CI or screen-layout verification is claimed.
Automatic voice/gesture grouping, embedded clocks, message insertion/removal,
raw practice editing and MIDI2 Clip import remain under #44748. Beat input does
not add a tempo map or stretch recorded audio. The full sequencer goal stays open.
