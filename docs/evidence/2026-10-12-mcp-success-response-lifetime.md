# MCP successful and forbidden response cleanup

Parent: `de3770dca9fa1ff308a710515dbb6e4c2dacc72b` (#42432).

Actual ReadableStream fixtures reproduced two resource failures: credential replacement while a successful response body was stalled did not cancel the body, and a 403 response was rejected without disposing its body. Both observed zero cancellations where one was required. The failed run is retained at `/tmp/mcp-response-lifetime-red-20261012.log`.

Successful response reads now pipe the acquired body through an abortable stream tied to the admitted credential revision. Authentication replacement aborts that read; the original owner check preserves authentication supersession as the exposed failure. Listener cleanup runs on success and failure. The 403 branch cancels its unread body before recording the blocked credential revision.

Focused validation completed: `npx vitest run src/api/mcp-admission-ownership.test.ts src/api/mcp.test.ts` passed two suites / 39 tests (`/tmp/mcp-response-lifetime-focused-20261012.log`), and `npx tsc --noEmit` exited 0. The fixture observes actual stream cancellation and original failure identity. Existing actual response parsing and owned credential retry tests remain in the focused scope.

These are mocked-HTTP behavioral checks. No CI, installation, live provider/server, browser screenshot, TUI runtime or formal approval is claimed. Cancellation while waiting for response headers, pagination ownership, other HTTP preflight consumers and shared operator-action effects remain unverified boundaries. The full chat goal remains active.
