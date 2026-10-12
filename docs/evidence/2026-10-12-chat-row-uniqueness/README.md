# Shared chat row field uniqueness

Base: d2bda3b5727ae505ded23cef3954aec387f0fafe.

Duplicate turn_ref on an unaddressed row passed pair decoding as Ok None, then
acquired autonomous execution authority from the first reference. Storage's
validate_row_fields checked allowed names, not duplicates. Share a pure row
field uniqueness check between that storage validator and row provenance
decoding. Row decoding checks uniqueness before absent provenance can admit an
explicit autonomous reference. Unknown unique fields remain outside this check;
existing storage allowed-name restrictions remain unchanged.

Artifacts: /tmp/masc-chat-row-uniqueness-20261012/.
Whole parent/current delivery codecs, real Turn_ref parser, actual history source
helpers and storage row validation functions were interpreted. The storage
validator module qualifier is adapted to the harness module name. Checkpoint,
trace-id and execution-id surroundings are minimal stubs outside exercised cases.
Parent exits 1 for duplicate Turn_ref execution authority. Current exits 0 for
refusal of that authority, repeated content/role/turn_ref rejection in both row
codec and storage validator, and retention of unique unaddressed rows.
This does not execute storage I/O, complete History.decode or UI rendering.

Four changed OCaml files passed syntax-only parsing; diff whitespace check passed.
Registered protocol fixture is unexecuted. Full typecheck/build, history/storage
integration, installed runtime, UI/screenshots, CI, approval and merge remain
unverified. Row text can still be retained as unowned presentation when its
provenance decoder returns Error; no full malformed-row quarantine is asserted.

Correction to earlier review interpretation: storage validate_row_fields was
an unknown-field guard, not a duplicate-field guard. The observed parent
implementation and this new shared uniqueness check establish that distinction.
