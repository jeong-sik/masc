# Authentication ownership of held approval rows

Base: c7b014285e0f4b5f8a377ed91e514cfcdd21d2a3.

Actual fetch-boundary RED: after account replacement, an old retained approval row still dispatched its decision under the new account. 1 failed / 13 passed; /tmp/chat-tool-approval-auth-red.log.

Approval rows now hold the existing authentication revision stamped by the shared immutable upsert writer. Answer and update paths reject foreign rows. Hydration may replace an old-account row with a current-account inventory entry. The mounted approval card reads the existing readonly credential-revision projection, filters foreign rows, and rehydrates when that revision changes. No credential copy or independent epoch was introduced.

Validation: 3 suites / 146 tests passed, including actual mounted Preact DOM retirement + rehydration callback, actual API/fetch answer ownership, and stream projection; /tmp/chat-tool-approval-auth-green.log. Mounted test stubs hydration itself, so it proves the callback and DOM behavior rather than a real network reload. TypeScript noEmit exit 0; /tmp/chat-tool-approval-auth-types.log. git diff --check passed.

No installed TUI, real provider execution, screenshot, CI or formal approval evidence. Server wait incarnation/frontier, unseen settlement, resource-safe retirement and publication/integration remain unfinished.
