# Autonomous history turn sequence

Base: `56e18790953578450fc113e4e58a514f3f6af034` (#42510).

Canonical autonomous history can carry its turn identity in `autonomous_turn.turn_id` without a redundant `turn_ref`. The decoder already used the marker for turn membership and journal execution source, but `turn_sequence_of_fields` ignored it. The authoritative absolute sequence was therefore absent from projected rows and unavailable to `compare_projected_chat_row_tie` in `masc_tui_types.ml`.

Share one source selector across explicit turn membership fallback, autonomous execution source and absolute turn sequence. An explicit turn_ref retains precedence, including malformed explicit references: no valid marker is used to invent a sequence for invalid explicit data. Operation delivery ownership is unchanged. Existing registered identity/state fixture now uses the producer's marker-only shape, retaining the structural identity and sequence checks; no layout or row-order test added.

Measured unchanged extracted production source selection, string-field decoding and actual Turn_ref parser with OCaml interpreter: parent exit1 (marker lost absolute sequence); current exit0 for marker-only sequence, explicit reference priority, invalid explicit reference, invalid marker and no marker. Harness/logs: `/tmp/masc-tui-autonomous-turn-sequence-20261012/`. This is isolated selector/parser execution, not complete history decoding or rendered timeline verification.

Syntax-only parsing passed for two changed OCaml files; diff whitespace passed. Complete history fixture is unexecuted. No full typecheck/build/CI, installed runtime, screenshots, formal approval or merge. Queue/interleaving/broadcast/async/provider parity and the broad goal remain incomplete.
