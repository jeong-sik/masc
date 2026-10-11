# Tool approval answer publication ownership

Base: 39b7ab14a74981b031b7e20a9a864bb8a34be14b.

Actual fetch-boundary reproduction: while an approval POST is pending, a new wait replaces the same Keeper/provider tool-call ID. The old successful response incorrectly settled that new row. Before repair: 1 failed, 6 passed (/tmp/chat-tool-approval-owner-red.log).

Updates now return immutable publication receipts and compare the expected row before writing. The answer owns its exact claimed row and captured authentication revision, checks ownership after observable claim publication before transport, and gates success/error publication. The updater rereads the map after computing the next row to preserve unrelated reentrant updates.

Focused actual API/fetch and signals-observer tests: 9 passed (/tmp/chat-tool-approval-owner-green.log). TypeScript noEmit passed before the two additional tests; final test-file type validation remains to be refreshed. Whitespace check passed.

Limits: backend wait identity is still keyed by Keeper and provider call ID. This repair protects late local HTTP publication, not server-side wait incarnation, late stream SETTLED, or hydration ownership. No formal approval, CI, installed runtime or screenshot evidence is claimed.
