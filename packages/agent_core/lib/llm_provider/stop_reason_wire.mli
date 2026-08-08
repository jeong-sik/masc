(** Single source of truth for OpenAI-compatible wire finish-reason ->
    {!Types.stop_reason} mapping, and the invariant that a tool-use stop must
    carry at least one tool block.

    Before this module the mapping was duplicated across the non-streaming parser
    ([Backend_openai_parse]) and the streaming chunk handler ([Streaming]) with
    divergent guards: the streaming path emitted [StopToolUse] for
    [finish_reason = "tool_calls"] WITHOUT checking that any tool block was
    actually assembled. A reasoning-only / dropped-partial-tool stream therefore
    reached the agent driver as a tool-use turn carrying zero tools, which the
    pipeline re-issued forever (the "infinite Thinking turn" defect).

    The OpenAI streaming finish chunk does not carry tool information (tool
    arguments arrive as deltas in earlier chunks), so the guard cannot be applied
    at the chunk boundary. The chunk records a provisional reason
    ({!provisional_of_string}); the accumulator applies the invariant once the
    full block set is known ({!reconcile}). *)

type wire_finish =
  | Tool_calls
  | Length
  | Stop
  | Refusal
  | Content_filter
  | Repetition_truncation
  | Context_window_exceeded
  | Other of string

(** Case-insensitive OpenAI-compatible vocabulary. OpenAI-specific
    ["tool_calls"] and ["stop"] are handled here because the canonical
    {!Types.stop_reason_of_string} spellings are ["tool_use"] and ["end_turn"].
    All other canonical and provider-dialect tokens are owned by that decoder
    and translated from its typed result. Thus an overflow token reaches
    [Context_window_exceeded] without duplicating its wire spellings here. *)
val wire_finish_of_string : string -> wire_finish

(** Canonical parse-time mapping for backends that know the assembled tool-block
    set at parse time (the non-streaming OpenAI parser). [Tool_calls] without a
    tool block fails closed to [UnmatchedToolCalls]. [Other] re-decodes through
    {!Types.stop_reason_of_string}: canonical tokens outside this module's
    vocabulary keep their typed value and unrecognized tokens stay [Unknown].
    No token reaching [Other] maps to executable [StopToolUse]. [Stop]
    (finish_reason=stop/end_turn) with a tool block present upgrades to
    [StopToolUse] — a provider that emits complete tool_calls but labels the
    turn as normal completion is mislabeling a tool-request turn, and the
    tool-block presence is authoritative. [Length] stays [MaxTokens] even with a
    tool block, since a length-truncated tool call may be incomplete. *)
val of_finish : wire_finish -> has_tool_blocks:bool -> Types.stop_reason

(** Faithful wire claim for the streaming chunk boundary, where the accumulated
    tool-block set is NOT yet known. The result MUST be passed through
    {!reconcile} once accumulation completes; see
    [Complete_stream_acc.finalize_stream_acc]. *)
val provisional_of_string : string -> Types.stop_reason

(** Enforce parse-time parity after streaming accumulation. Maps [StopToolUse]
    with [has_tool_blocks = false] to [UnmatchedToolCalls] and maps [EndTurn]
    with [has_tool_blocks = true] to [StopToolUse] (a finish_reason=stop
    alongside complete tool blocks is a provider mislabel of a tool-request
    turn) so these labels follow {!of_finish}. [Unknown], [MaxTokens], and the
    other terminal reasons are left unchanged even with tool blocks — an
    unrecognized, truncated, or terminally-flagged turn must not auto-execute a
    possibly-incomplete tool call. Total over {!Types.stop_reason}: no catch-all,
    so a new [stop_reason] constructor forces a compile error here. *)
val reconcile : Types.stop_reason -> has_tool_blocks:bool -> Types.stop_reason

(** [true] only for the typed fail-closed value produced when a provider
    reported a tool-use finish but the assembled response carried no tool
    block. Consumers that need to distinguish this executable-shape invariant
    from arbitrary unknown stop reasons should use this predicate. *)
val is_unmatched_tool_calls : Types.stop_reason -> bool
