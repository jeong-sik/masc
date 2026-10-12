# Credential replacement cancels MCP header acquisition

Parent response-lifetime branch commit: `3f55923439` (#42433).

A real fetch AbortSignal fixture reproduced a request still waiting for headers after credential replacement: its signal remained un-aborted (`/tmp/mcp-header-acquisition-red-20261012.log`). The fixture releases its deferred response in finally on failure rather than abandoning an outstanding request.

MCP now owns an acquisition AbortController subscribed to the admitted credential lifetime. Replacement aborts fetch. The catch validates the original binding so a superseded request reports authentication change rather than generic abort, timeout or tool-host failure. The subscription is released on every acquisition outcome. Existing acquired-response disposal still handles transports that resolve a late response despite abort.

Focused checks completed successfully: two suites / 40 tests with `npx vitest run src/api/mcp-admission-ownership.test.ts src/api/mcp.test.ts` (`/tmp/mcp-header-acquisition-focused-20261012.log`), and `npx tsc --noEmit` exit 0. No live server/provider, screenshot, installation, CI or formal approval is claimed. Pagination, other HTTP bootstrap consumers and shared operator-action effects remain outstanding; this does not complete the chat goal.
