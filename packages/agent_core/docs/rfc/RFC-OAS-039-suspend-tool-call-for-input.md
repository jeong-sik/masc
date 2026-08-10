# RFC-OAS-039: Synchronous exact-tool approval before execution

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-07-28 |
| Target | `agent_sdk` |
| Related | [[RFC-OAS-025]] (forced tool-use enforcement boundary) |

## 0. Summary

`Pre_tool_use` is the first hook stage that knows the exact tool occurrence and
input. This RFC admits `ElicitToolApproval` at that stage and settles it
through the separate caller-configured `options.tool_approval` callback before
the tool invocation is opened.

- Only the closed `Approved` result authorizes the exact call.
- `Denied` and `Timed_out` produce a typed non-retryable `ToolResult` without
  executing the tool.
- A missing callback fails closed as `Hook_execution_failed`; no invocation or
  effect is started.

This is deliberately a synchronous authorization gate, not an SDK-owned
durable suspension. OAS installs no timer, stores no pending approval request,
and exposes no resume token here. The callback must settle any remote prompt,
deadline, or restart policy before it returns; `Timed_out` reports a deadline
already enforced by the caller. A callback that does not return blocks its
dispatch fiber by contract.

The before-turn `Agent.provide_input` API is intentionally not reused. It
appends a `User` message and has different transcript semantics.

## 1. Problem

Before this change, the hook decision matrix accepted `ElicitInput` only at
`Before_turn`. A caller that needs approval for one exact tool call could not
ask after the provider had selected both the tool and its input.

Encoding a pending decision as a successful tool result is incorrect:
`tool_result_outcome` has only `Tool_succeeded` and `Tool_failed`, and provider
wire formats require every emitted result to describe a completed call.

## 2. Decision

The legal decisions are:

```ocaml
| Before_turn  -> [ K_Continue; K_ElicitInput; K_Nudge ]
| Pre_tool_use -> [ K_Continue; K_Block; K_ElicitToolApproval ]
```

When a `Pre_tool_use` hook returns `ElicitToolApproval prompt`,
`Agent_tools.execute_tools` creates an immutable request containing that prompt,
the exact invocation, tool name, and input, then consults the configured typed
callback:

```ocaml
match options.tool_approval exact_request with
| Approved -> execute_the_exact_call ()
| Denied -> blocked_tool_result "Tool execution was denied by the caller"
| Timed_out -> blocked_tool_result "Tool execution approval timed out"
```

Generic `Answer of Yojson.Safe.t` and a JSON Schema are deliberately absent from
this boundary. They express user input, not execution authority; accepting a
schema-shaped JSON value would reintroduce an untyped approval protocol. A
generic `ElicitInput` returned at `Pre_tool_use` is stage-illegal and fails
closed before its callback or any effect runs. The approval result is not
appended as a `User` message. A refusal is represented as the same
model-visible, deterministic failure shape used by `Hooks.Block`, and no tool
lifecycle event is emitted for an effect that never started.

A non-reserved callback exception is a typed `Hook_execution_failed` result
before invocation. Runtime cancellation and other reserved exceptions continue
to propagate through the surrounding structured-concurrency scope.

## 3. Fail-closed boundary

An asynchronous durable suspension is not implemented by this RFC.

Opening an invocation and returning `Error.InputRequired` is insufficient:

1. the generic execution runner closes ordinary `Error` results as failed;
2. merely finding an open invocation during resume cannot prove that the host
   approved it;
3. concurrent calls can create multiple pending decisions while a single
   request payload exposes only one;
4. checkpointing a sibling result while another call is pending creates a
   partial tool-result set that the durable resume topology correctly rejects.

A future asynchronous API therefore needs a typed journal event for the gate
request and its answer, a stage-specific public response method, atomic refusal
settlement, and an explicit partial-batch recovery contract. Until those types
exist, a missing callback fails before `open_invocation`.

## 4. Public contract

The hook decision matrix in `Hooks`, the README, and the event catalog all list
`ElicitToolApproval` as legal at `Pre_tool_use`.

The configured callback is honored consistently at both legal elicitation
stages, with stage-specific transcript behavior:

- `Before_turn`: an `Answer` may add a user message before provider dispatch.
- `Pre_tool_use`: an `Approved` result authorizes the exact call and adds no
  user message.

## 5. Verification

Focused tests must prove:

1. `ElicitToolApproval` is legal at `Pre_tool_use` and remains illegal at every
   other unsupported stage; generic `ElicitInput` is rejected there.
2. `Approved` executes the exact call once.
3. `Denied` and `Timed_out` execute it zero times and return a typed
   non-retryable failure.
4. Missing callback support fails closed before invocation/effect execution.
5. The public hook matrix and user-facing documentation agree with runtime
   validation.

## 6. Non-goals

- Adding a third provider-wire tool result state.
- Treating `_meta` as a control-flow protocol.
- Reusing before-turn `Agent.provide_input` for tool-gate answers.
- Claiming asynchronous or crash-resumable approval without durable typed
  request/response evidence.
