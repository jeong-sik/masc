(** Drop assistant [ToolUse] blocks whose [id] has no matching [ToolResult]
    anywhere in the message list, and drop any message emptied as a result.

    Provider APIs (OpenAI-compatible, Anthropic) reject a request whose
    assistant [tool_calls] are not each answered by a tool result: "an
    assistant message with 'tool_calls' must be followed by tool messages
    responding to each 'tool_call_id'". A well-formed request never carries
    such an orphan, so [drop] is a no-op there (returns the input list
    physically unchanged) and only repairs a list the provider would otherwise
    reject — it cannot break a valid request.

    Root cause: a [ToolUse] persisted without its [ToolResult] (a turn
    interrupted between the call and its result) then replayed every turn,
    wedging the keeper (#25278). Applied at the single outgoing-request
    chokepoint so no assembly path can leak an orphan.

    Orphan [ToolResult] blocks (a result with no preceding call) are left
    untouched: OAS preserves them by contract ([backend_openai] "preserves
    orphaned tool results without synthetic repair") and they do not trigger
    the assistant-tool_calls invariant. *)
val drop : Agent_sdk.Types.message list -> Agent_sdk.Types.message list
