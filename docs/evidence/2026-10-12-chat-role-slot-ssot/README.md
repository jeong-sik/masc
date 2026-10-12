# Shared delivery role and slot authority

Base: 7bcfd0e446a1553b00f52045612d4db65b109ffc.

Durable storage rejected role/slot conflicts, while TUI history decoded the
provenance pair without the same role check. An assistant under Accepted_user
could gain reply output authority. Move the existing storage validation table
unchanged into keeper_chat_delivery_identity. Storage calls the shared validator;
TUI uses row_delivery_provenance_of_fields, which decodes the canonical pair and
validates the row role before granting source ownership. Pair-only decoding is
retained for non-row consumers. Unaddressed rows remain Ok None. Protocol role
labels are decoded at this shared boundary; no body text heuristics are used.

Artifacts: /tmp/masc-chat-role-slot-ssot-20261012/.
Parent/current production source helpers run against the actual shared codec and
actual Turn_ref parser, with minimal checkpoint/trace-id/execution-id surroundings
outside the exercised cases. Parent exits 1 for role/slot ownership conflict;
current exits 0 for assistant/input, user/terminal, tool/input and system/terminal
refusals plus canonical user/input and assistant/failure terminal ownership.
Whole History.decode and storage writes are not executed by this harness.

Five changed OCaml files passed syntax-only parsing; diff whitespace check passed.
Registered history state fixture is unexecuted. Full typecheck/build, runtime,
UI/screenshots, CI, formal approval and merge remain unverified.
