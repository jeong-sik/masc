# Tool Execution Modes

OAS batches tool calls within a turn using only the caller-declared
[`execution_mode`](../lib/base/tool.mli) carried by `Tool.descriptor`:

- `Concurrent` — calls in a contiguous batch may overlap. OAS restores result
  order after `Eio.Fiber.List.map` completes.
- `Serial` — calls execute one at a time in model order.

A missing descriptor means `Serial`. OAS does not inspect a tool name, command,
path, input, effect, or product identity to choose a mode.

## Declaring a mode

```ocaml
open Agent_sdk

let lookup_tool =
  let descriptor = Tool.ordinary_descriptor Tool.Concurrent in
  Tool.create
    ~descriptor
    ~name:"lookup"
    ~description:"Look up a value"
    ~parameters:[]
    (fun _args -> Ok { Types.content = "value"; _meta = None })
```

The caller is authoritative. External-effect decisions are independent from
this structural scheduling declaration. An embedding application settles such
decisions before dispatch and may return `Hooks.Block reason` from its
`PreToolUse` hook to reject a call explicitly.

## Terminal tools

A terminal tool is serial and must be the only `ToolUse` in its provider turn.
Its failure effect boundary is explicit:

```ocaml
let descriptor =
  Tool.terminal_descriptor Tool.Effect_outcome_unknown
```

Only `Tool.Proven_pre_effect` authorizes another provider turn after a typed
handler error. `Tool.Proven_post_effect` and
`Tool.Effect_outcome_unknown` stop without a second provider call and surface
`Error.TerminalToolEffectFailed` with a typed effect disposition. Input
validation failures remain correction-capable because OAS proves that the
handler did not run. An ordinary tool-handler exception is localized to a
non-retryable result; a terminal tool-handler exception instead propagates
with its original backtrace because no typed pre-effect proof exists.

Completion is copied into the immutable invocation and persisted in execution
event schema v2. Durable resume reads that persisted value only. It never
reconstructs completion from the current tool catalog, tool name, provider,
model, tier, pricing, or scheduling defaults. The v2 event and completion
object codecs are current-only; older runtime assets must be reset rather than
migrated.

See also:

- `lib/agent/agent_tools.ml` for batching.
- `examples/tool_use.ml` for mixed explicit modes.
- `examples/async_agent_demo.ml` for async agents using tool descriptors.
