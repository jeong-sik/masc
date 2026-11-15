### Fixed

- A Lane package's action, binding and output schemas are checked under their
  own `Declared_schema` contract instead of the host tool contract. A required
  member whose name starts with `_` is no longer dropped before the check and
  refused as missing, and an action tool named `masc_transition` no longer
  refuses its own declared `to` and `note` members as retired transition
  aliases. Undeclared members, closed objects, types, enums and ranges are
  checked as before, and host tool calls keep both rules (#51861, #PENDING).
