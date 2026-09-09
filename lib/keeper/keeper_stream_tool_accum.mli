(** Turn-local collector for the tool calls a keeper made during one chat
    stream, so the persisted turn keeps them and a reload still shows the tool
    timeline.

    The chat stream already carries [ContentBlockStart] with a tool identity
    and [InputJsonDelta]/[InputJsonSnapshot] argument fragments, but the
    persist site had no way to read them: only generated media was collected
    ({!Keeper_stream_media_accum}), so [append_turn_result] was called without
    [?tool_calls] and history rows carried no tool rows at all. The live
    transcript therefore showed tool steps while the stream was open and lost
    them on reload.

    Mirrors the media collector's shape deliberately: a turn-local mutable
    accumulator fed the same raw events, kept separate from the SSE bridge so
    live translation and durable persistence stay on their own side of the
    AGENT_CORE-stream / chat-store boundary. *)

type t

val create : unit -> t

val current_stream_scope : t -> int
(** Server-owned scope selected by the latest processed stream event. The raw
    event and live bridge carry this exact value; consumers never reconstruct
    it from provider ids. *)

val current_scope_is_sealed : t -> bool
(** Whether Agent Core already closed the current provider-call scope with or
    without exact tool sources. Outer failures must not revoke that sealed
    evidence. *)

val start_runtime_attempt
  :  t
  -> Keeper_chat_events.runtime_attempt_scope_disposition
(** Mark the exact resolved-candidate attempt boundary before its first stream
    event. The first attempt retains the initial scope; every later attempt
    advances to a fresh scope and quarantines every unsealed row from the
    failed attempt, including syntactically finalized tool blocks. Already
    sealed source evidence remains append-only. The returned closed disposition
    carries that same pre-advance authority so the live bridge cannot
    independently disagree about whether to tombstone the prior scope. This lets
    blank provider message ids replay within one attempt without aliasing a
    lane fallback or outer retry. *)

val on_event : t -> Agent_core.Types.sse_event -> unit
(** Feed one raw AGENT_CORE stream event. A tool-bearing [ContentBlockStart] opens a
    block, argument deltas append to it, and [ContentBlockStop] / [MessageStop]
    finalize. Snapshots replace the accumulated fragments rather than appending,
    matching the provider contract. The next raw event after [seal_turn]
    starts a fresh server scope even when the provider message id is blank or
    reused. Within an unsealed response, an exact repeated [MessageStart]
    retains its scope; a different message quarantines any open tool occurrence
    before starting a fresh message scope. A duplicate tool start is idempotent
    only before payload; after payload or stop it is quarantined. A [MediaDelta]
    marks its index as media-occupied until the block's terminator. Canonical
    producer streams announce media first; bare-media handling remains a defense
    for direct callers. Other non-tool events are ignored. *)

val seal_turn :
  t ->
  turn:int ->
  tool_source_map:Agent_core.Hooks.admitted_tool_source_map ->
  (unit, string) result
(** Bind the current server stream scope to one Agent Core turn and its exact
    admission mapping. [source_tool_use_ordinal] enumerates the trusted streamed
    tool blocks in raw block-index order, including calls admission later
    rejected; [source_tool_use_count] proves the complete trusted stream
    inventory, including the all-rejected case. Neither fact is reconstructed
    from provider ids. Planned indices must be unique and contiguous. The
    resulting mapping is the only authority later used by
    {!record_execution_id}. *)

val close_turn_without_sources : t -> turn:int -> (unit, string) result
(** Close the current scope for an official-client producer that cannot expose
    a pre-execution source sidecar. Calls in this scope remain delivery-only;
    later execution callbacks fail explicitly instead of selecting by provider
    id or inferred ordinal. *)

val record_execution_id :
  t ->
  tool_call_id:string ->
  turn:int ->
  planned_index:int ->
  execution_id:Ids.Execution_id.t ->
  (Keeper_chat_events.tool_stream_occurrence, string) result
(** Attach the canonical identity after the exact tool-call log row commits.
    [turn] and [planned_index] select the producer-owned admission mapping
    previously committed by {!seal_turn}; the provider id is only an optional
    exact cross-check. Reuse or absence of a provider id is therefore valid.
    The returned message/block occurrence is
    the live row authority. A missing, conflicting, or multiply-matching
    occurrence is an error, never a provider-id guess. *)

val take_protocol_errors :
  t ->
  ( Keeper_chat_events.stream_protocol_error_kind
    * Keeper_chat_events.tool_stream_occurrence
    * string )
    list
(** Drain stream-integrity failures observed since the prior call. An event
    whose lifecycle or delta kind conflicts with the exact occurrence is
    quarantined from persistence and reported with its typed protocol kind. *)

val to_tool_calls : t -> Keeper_chat_store.tool_call list
(** The tool calls finalized so far, in the order the provider opened them.
    Quarantined protocol conflicts are omitted. Providerless rows remain visible
    as delivery evidence and may still receive canonical execution identity
    through the producer-owned admission mapping. *)

val to_tool_calls_for_failure : t -> Keeper_chat_store.tool_call list
(** Atomically invalidate an unsealed active provider scope and snapshot only
    failure-safe tool rows. A scope already sealed by Agent Core is immutable
    execution evidence and is retained. *)
