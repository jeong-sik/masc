# Strict approval inventory boundary

Base: d3dcc6682877c2e6508d954297967f252189a0fe.

Actual fetch/API RED: missing pending, non-array pending, partial row and null row were accepted as empty inventory or invented prompt fields. 4 failed / 14 passed; /tmp/chat-tool-approval-inventory-decode-red.log.

Inventory now requires a record envelope and pending array. Every row is validated before returning the list: required strings retain source text, question/identity/tool must be nonblank, reason and serialized args must be strings, and clock/policy seconds must be null or finite nonnegative numbers. Bad input rejects instead of defaulting missing fields. Hydration remains best-effort and does not publish any partially decoded list.

Validation: actual approval API and broader Keeper API suites, 73 tests passed; /tmp/chat-tool-approval-inventory-decode-green.log. TypeScript noEmit exit 0; /tmp/chat-tool-approval-inventory-decode-types.log. Whitespace check passed. No installed runtime, screenshots, CI or formal approval claim.

Server wait incarnation/frontier, unseen terminal observations, provider/runtime checks and integration remain unfinished. GitHub publication attempt encountered intermittent api.github.com connection failure in this turn; this does not prevent source work.
