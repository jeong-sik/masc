# Exact authored musical timing

Base: `dbd543dd6e1e8d395b915875a34a2a6d6c8e2f20`.

An actual source-TUI composition exercise exposed a command-boundary defect:
`note C4 8.3 1 91` rejected a valid 7968-tick position because Number('8.3')
times PPQ960 produces 7968.000000000001. Integer fractions worked in MIDI step
controls but not ordinary phrase/source positions or note selections.

One pure parser now converts authored decimals or integer fractions using
BigInt before checking divisibility and safe native tick range. Phrase and
arrangement beats, imported-source positions, selected-note positions/offsets
and step lengths/rests share it. MIDI clocks, stored ticks, wall-clock
conversion and serialization are unchanged. Signed offsets remain explicit.
Hexadecimal/exponent input is refused; unsupported precision is not rounded.

Six focused Node suites passed **33/33**, zero failed/skipped/cancelled:
exact-position, sequencer-editor, midi-source-editor, note-selection,
step-controls and phrase-arrangement. These exercise actual phrase editing,
PPQ1001/SMPTE80 source input, controller and release preservation through real
SMF export/reimport, undo, selection movement, arrangement cursor/grid and
transactional refusal. The regression includes a 1/3-beat phrase and a 1/7-beat
PPQ1001 source; nonintegral source positions are still refused.

No full regression, local Dune, installed OCaml-parent integration, audio-device
latency, physical MIDI or audible-output result is claimed. This fixes authored
musical timing, not external MIDI clock synchronization. The wider sequencer
goal remains active.
