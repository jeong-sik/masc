# RFC-OAS-025: Forced-Tool-Use Enforcement Boundary

| Field | Value |
|---|---|
| Status | Implemented |
| Author | vincent (drafted by agent) |
| Created | 2026-06-04 |
| Implemented | 2026-07-14 hard cut |
| Target | `agent_sdk` (oas) |

## 0. Decision

OAS sends the caller's typed `tool_choice` to the selected provider but does
not re-interpret a text response as a tool call, validate the response against
an OAS-owned forced-tool completion contract, or retry to coerce a tool call.
The provider response or typed provider error is returned after one attempt.

Any later attempt, local-model coercion, or external validation belongs to the
embedding application. This keeps provider request construction in OAS while
leaving orchestration policy outside the SDK.

## 1. Historical problem

The pre-implementation design mapped `tool_choice` to an OAS completion
contract, checked the response against that contract, and could feed a
"you must call a tool" message into another turn. That mixed three distinct
concerns:

1. serializing the caller's provider request;
2. observing whether the provider honored it; and
3. deciding whether and how to make another attempt.

The third concern consumed turns and embedded retry/coercion policy in the SDK.
The deleted implementation lived in `completion_contract.ml` and the former
pipeline recovery path. Those names are historical evidence, not current API
or source locations.

## 2. Implemented boundary

- `tool_choice` remains part of the typed request and provider serializers.
- Only a provider-native typed `ToolUse` block can reach tool dispatch.
- Text remains text; OAS has no text-to-tool recovery fallback.
- OAS performs no automatic retry or corrective prompt injection to enforce
  `tool_choice` after a provider returns. Ordinary typed tool-use continuation
  remains part of the agent loop and is not a retry.
- Non-compliant local backends may return text even when the request asked for
  a tool. OAS returns that response unchanged.
- A caller that requires an additional invariant inspects the typed response and
  schedules any later attempt outside the completed OAS call.

## 3. Removed surface

The implementation deleted, rather than deprecated or toggled, the following
OAS-owned policy surface:

- forced-tool response completion contracts;
- `CompletionContractViolation` recovery flow;
- `tool_retry_policy` and its corrective prompt;
- retry-count and turn-burning coercion behavior;
- compatibility modes such as `Enforce | Report_only | Off`.

Restoring any of these as a default, hidden fallback, or environment-driven
mode would reverse this RFC. If an embedding product needs such behavior, it
owns the typed validator, model judgment, and asynchronous scheduling policy.

## 4. Migration

Consumers that previously relied on OAS to coerce a non-compliant backend must:

1. inspect the returned `Types.api_response` for the required typed `ToolUse`;
2. record or present any mismatch at their own boundary; and
3. decide independently whether to accept the text, ask a model judge, involve
   a human, change provider/runtime, or schedule another attempt.

No consumer should scrape free text or repair JSON into a synthetic tool call.

## 5. Acceptance invariants

- Provider request-shape tests prove `tool_choice` still reaches supported
  provider serializers.
- A text-only response is returned as text, not a completion-contract error.
- Each completion invocation performs one provider attempt. A later typed
  tool-use continuation is a distinct invocation, not a hidden retry.
- No deleted completion-contract or tool-retry symbol is exported or referenced
  by active source and tests.
- The breaking surface removal is recorded in `CHANGELOG.md`.

## 6. Relationship to the current standard

RFC-OAS-029 S4.2 is the corresponding tool-dispatch invariant: `Text` is not
`ToolUse`. RFC-OAS-025 records the completed ownership decision; it is no longer
an option analysis or implementation backlog.
