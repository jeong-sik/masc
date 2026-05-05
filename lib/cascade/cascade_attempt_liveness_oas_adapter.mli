(** OAS [Agent_sdk.Types.sse_event] → [Cascade_attempt_liveness.Stream_chunk.kind]
    adapter (RFC-0022 PR-3/4).

    Pure mapping. Returns [None] for events that do not represent
    forward motion or completion (e.g. [SSEError], which is surfaced
    via [Provider_wire_error] elsewhere). All variants that DO
    represent activity map to a kind such that
    [Cascade_attempt_liveness.step] advances the chunk clock
    (Invariants S1, T1).

    Stable for telemetry: any kind/[type sse_event] addition in
    [Agent_sdk] requires an explicit branch here so unfamiliar variants
    do not silently starve the FSM (which would surface as a
    [No_first_token] or [Inter_chunk_idle] kill on the next [Tick]).

    @since RFC-0022 PR-3 *)

val kind_of_sse_event :
  Agent_sdk.Types.sse_event ->
  Cascade_attempt_liveness.Stream_chunk.kind option
(** Map an SSE event variant to a stream chunk kind, if applicable. *)
