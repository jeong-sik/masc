# Authentication recovery keeps the admitted request owner

Parent: `bacf193845698dcc7d1551c5d704abe1d606042c` (#42429).

An MCP tool request could receive an authentication failure, wait for development-token recovery, and then retry under a credential installed by another session. Recovery now returns the exact bound credential transition instead of a boolean. MCP and Keeper stream retries carry that transition and reject external replacements before dispatch. The original tool arguments remain unchanged on an owned retry.

The real core/dev-token/MCP fixture first reproduced two tool POSTs where one was expected after an external replacement (`/tmp/mcp-recovery-red-20261012.log`). Positive coverage observes both actual Authorization headers and original tool input across owned recovery. Keeper coverage rejects a deferred old refresh without a second stream POST or event publication.

Two resource failures were reproduced separately: an authentication change while reading a stalled HTTP error body did not cancel its stream (`/tmp/mcp-error-body-red-20261012.log`); a failed response arriving after credential replacement was rejected without disposing its acquired body (`/tmp/mcp-stale-headers-red-20261012.log`). Error-body parsing now subscribes to credential changes and aborts its real body pipe. A superseded acquired response is cancelled before rethrowing the authentication change. Actual ReadableStream cancellation is observed in the fixtures.

Validation commands from dashboard:

```sh
npx vitest run src/api/mcp-admission-ownership.test.ts src/api/mcp.test.ts src/api/dev-token.test.ts src/api/keeper.test.ts src/store-shell-auth.test.ts
npx tsc --noEmit
```

Both commands completed successfully: five suites / 115 tests passed, and TypeScript noEmit exited 0. The focused test output is retained at `/tmp/mcp-recovery-focused-20261012.log`. These are focused mocked-HTTP behavioral checks, not live provider/server evidence. No CI, installation, browser screenshot, TUI runtime verification or formal GitHub approval is claimed.

Remaining resource scope: auth-driven cancellation during successful MCP body reads, header acquisition and current-owner 403 disposal. Other HTTP preflight consumers, paginated MCP aggregates and shared operator-action publication still require their own ownership checks. This repair does not certify whole-account isolation or complete the chat corner-case goal.
