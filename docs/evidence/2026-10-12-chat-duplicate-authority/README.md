# Duplicate delivery row authority

Base: 740fb18691cea0b7dbe8079c02eaac95e3cf28f6.

The pair decoder selected the first delivery_key/transcript_slot when JSON object
fields were repeated. Its row-aware extension likewise selected the first role.
Reject repeated authority fields explicitly at the shared codec boundary rather
than selecting one of several asserted identities. No arbitrary field-count cap
or content-pattern heuristic is introduced. Absent provenance remains unowned;
unaddressed row roles are outside this authority validation scope.

Artifacts: /tmp/masc-chat-duplicate-authority-20261012/.
Whole parent/current delivery codec modules are interpreted with actual Yojson
and minimal checkpoint/trace-id/execution-id surroundings. The exercised cases
use Operation keys only and do not validate the stubbed payload modules. Parent
exits 1 when duplicate authority is accepted; current exits 0 for duplicate key,
slot, identical and conflicting roles, plus unique row, absent pair and half-pair
checks. This is real codec execution, not whole storage or TUI ingestion proof.

Three changed OCaml files passed syntax-only parsing and diff whitespace check.
Protocol fixture added but unexecuted. Full typecheck/build, storage writes,
history pipeline, runtime, UI/screenshots, CI, formal approval and merge remain
unverified. Other repeated row fields, including turn_ref, are not certified by
this bounded change.
