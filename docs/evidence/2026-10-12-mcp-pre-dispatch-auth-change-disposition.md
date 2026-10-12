# Pre-dispatch MCP credential change classifies as a known pre-effect failure

Parent: `75277da5f7dd828de717ed82a5011b4ee39e5bbe` (#42429).

Codex automated review (P2, `dashboard/src/api/mcp.ts:267`) identified that when the
credential changes while `ensureDevToken()` is pending, `ensureBinding()` rejects before
any `/mcp` request is dispatched, but the thrown `authChangedError()` is a plain `Error`,
so `mcpCallFailureDisposition()` classifies the attempt as `outcome_unknown`. `sendBroadcast()`
then converts this known-unsent attempt into a "do not resend" receipt instead of surfacing a
retryable pre-effect failure.

The dispatch-rejection branch in `ensureBinding()` now throws a distinct
`McpPreDispatchAuthChangedError` (same message, typed subclass), and
`mcpCallFailureDisposition()` maps that type to `known_pre_effect`. Auth changes detected
after `fetchWithTimeout()` starts still throw the plain `authChangedError()` and keep the
genuinely unknown `outcome_unknown` classification, because the request may have reached
the tool. Classification uses `instanceof` on the closed error types, not message matching.

Focused checks completed: `vitest run src/api/mcp.test.ts src/api/mcp-admission-ownership.test.ts
src/api/actions.test.ts` passed three suites / 49 tests, and `tsc --noEmit` exited 0.
A new fixture pins the pre-dispatch case (bootstrap superseded mid-flight, no `tools/call`
request recorded, disposition `known_pre_effect`) and the existing post-dispatch fixture
now also asserts `outcome_unknown`. No live provider/server, screenshot, installation, CI
or formal approval is claimed.
