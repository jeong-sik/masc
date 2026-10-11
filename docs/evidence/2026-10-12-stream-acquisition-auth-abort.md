# Authentication ownership while stream headers are pending

Base: `09b856fded48f11c8f279d89d0fe057caf3320b7` (#42413).

The chat API previously subscribed to token changes only after acquiring the response body reader. An admitted POST waiting for headers kept its fetch alive after credentials changed.

The final pending-acquisition fixture was run against an isolated base worktree and failed: the actual signal passed to fetch remained unaborted after token replacement. The fixture supplies a caller signal and asserts that the caller controller itself is not mutated. The fetch mock is explicitly rejected for cleanup so the test failure cannot leave an unresolved request.

Each POST attempt now owns an acquisition controller and composes it with the caller signal using native AbortSignal.any. Its token listener is installed before the admission callback/fetch, and released in finally after headers or failure. Authentication withdrawal continues to report the typed superseded error; caller cancellation remains AbortError. Each 401 retry starts a fresh attempt with fresh headers and owner. Existing acquired-body reader cancellation and stale response-body disposal remain separate existing paths.

Focused API, shared-action and Copilot tests: 195 passed. TypeScript noEmit and diff-check passed. Initial hostile source review found no P0-P2 in the two-file implementation/test scope.

This establishes mocked transport signal ownership, not actual browser network termination or Keeper-side operation cancellation. Authentication changes while consuming an HTTP error body, account-scoped cached transcript isolation, live provider/async/broadcast continuity, installation and real UI screenshots remain unverified/separate work. No formal approval, merge, runtime or CI evidence is claimed.
