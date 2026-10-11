# Header-aware GET body cancellation

Base: df705dc631f0313293f15829dcb19ddbc53c2cd0. Direct consumer: api/workspace.ts fetchWorkspaceTree, which reads selected response headers alongside parsed data.

Two parent fixtures failed: caller cancellation during a stalled 200 or 500 body did not abort the actual signal passed to fetch. The fixture models native fetch body abort using that signal and always releases its controlled stream. RED: /tmp/header-aware-body-red-20261012.log.

getWithResponse now consumes success/error/warm bodies inside the existing fetchWithTimeout consumer boundary, retaining its caller-abort connection and configured deadline until parsing completes. Its public data/header return contract and empty-header warm fallback are preserved. A positive fixture verifies actual selected header and parsed data retention.

Two focused suites (core and operator-refresh-http-ownership) passed 67 tests. TypeScript noEmit exited 0. Log: /tmp/header-aware-body-focused-20261012.log. No actual socket/browser/provider, screenshot, CI, approval or installation evidence. Other HTTP verbs and full chat-runtime continuity remain separate scopes.
