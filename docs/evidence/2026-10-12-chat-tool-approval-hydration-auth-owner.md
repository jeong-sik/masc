# Approval hydration authentication ownership

Base: f4fbf146d230b8a828d27349d6a9cf8722da11d7.

Real API/fetch reproduction: a pending approval listing completed after account replacement and published the old account's wait into the current signal. Before repair: 1 failed / 9 passed; /tmp/chat-tool-approval-hydration-red.log.

Hydration now captures the existing authentication revision and checks it before every row publication. The per-row check also stops the rest of a listing after a synchronous signal observer changes authentication. No second authentication source or text heuristic was introduced.

Validation: actual fetch and synchronous signals observer paths, 11 tests passed; /tmp/chat-tool-approval-hydration-green.log. TypeScript noEmit completed successfully; /tmp/chat-tool-approval-hydration-types.log. git diff --check passed.

Scope limits: already published approval rows are not globally partitioned by account here. Request ordering within one account, stream settlement incarnation and server wait identity remain separate work. No runtime, screenshot, CI or formal approval claim.
