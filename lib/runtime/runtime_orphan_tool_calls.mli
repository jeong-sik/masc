(** Drop assistant [ToolUse] blocks whose [id] has no matching [ToolResult] on a
    later [Tool] message, and drop any message emptied as a result.

    Provider APIs (OpenAI-compatible, Anthropic) reject a request whose
    assistant [tool_calls] are not each answered by a tool result: "an
    assistant message with 'tool_calls' must be followed by tool messages
    responding to each 'tool_call_id'". A well-formed request never carries
    such an orphan, so [drop] is a no-op there (returns the input list
    physically unchanged) and only repairs a list the provider would otherwise
    reject — it cannot break a valid request.

    Role- and order-scoped to match the provider contract exactly: only
    [Assistant] [ToolUse] blocks are treated as calls needing an answer; a
    [ToolResult] counts as an answer on a [Tool]-role message (OpenAI wire
    format) or a [User]-role message (Anthropic wire format carries tool_result
    blocks in a user turn); and a result rescues a call only when it appears at a
    strictly later position — a result that precedes its call, or a [ToolUse] on
    a non-assistant message, does not satisfy the invariant. A [ToolResult] on a
    System or Assistant message never carries it, so it is not counted as an
    answer.

    Root cause: a [ToolUse] persisted without its [ToolResult] (a turn
    interrupted between the call and its result) then replayed every turn,
    wedging the keeper (#25278). Applied at the single outgoing-request
    chokepoint so no assembly path can leak an orphan.

    Orphan [ToolResult] blocks (a result with no preceding call) are left
    untouched: OAS preserves them by contract ([backend_openai] "preserves
    orphaned tool results without synthetic repair") and they do not trigger
    the assistant-tool_calls invariant. *)
val drop : Agent_sdk.Types.message list -> Agent_sdk.Types.message list
