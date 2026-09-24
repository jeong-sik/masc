(** Runtime_observation — one runtime's per-turn observation: the attempts it
    made, with their latency and errors, the model it selected, and its
    streaming timings, captured through AGENT_CORE's per-call metrics sink.

    Built per turn by the named-runtime runners through the
    {!runtime_metrics_for_candidates} + {!runtime_observation_with_metrics}
    pair. Dotted callers ({!Runtime_observation.X}) rely on the surface
    pinned here. *)

(** {1 Runtime observation types} *)

type runtime_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

type request_context = {
  input_tokens : int;
      (** Inclusive: uncached input plus both cache components. *)
  cache_creation_input_tokens : int;
  cache_read_input_tokens : int;
}
(** Input side of the newest provider request of the turn: how much of the
    context window that request occupied. A runtime that reports the turn's
    spend and the request's occupancy as two different counts (Claude Code's
    result frame vs. its assistant frames) carries the occupancy here, and
    the spend in the response usage under [usage_scope]. There is no output
    side: a request's output count seen mid-stream is not its final count. *)

type runtime_observation = {
  runtime_id : string;
  selected_model : string option;
  selected_model_raw : string option;
  attempts : runtime_attempt list;
  attempt_details_available : bool;
  attempt_details_source : string;
  agent_core_internal_runtime_allowed : bool;
  streaming_ttfrc_ms : float option;
  streaming_inter_chunk_count : int;
  streaming_inter_chunk_avg_ms : float option;
  usage_scope : Runtime_usage_scope.t;
  request_context : request_context option;
      (** [None] when the runtime reports no occupancy apart from its
          response usage. *)
}
(** Per-turn runtime execution snapshot.  [attempts] is
    in chronological order (the internal capture stores
    it reversed and {!runtime_observation_with_metrics}
    flips it on materialise).  [attempt_details_source]
    distinguishes the capture path (the canonical
    [agent_core_metrics_callbacks] tag vs legacy fallbacks) so
    operators can tell at-a-glance whether the per-call
    metrics sink was wired.

    This record describes one runtime's own attempt sequence
    ("runtime-internal candidate walk"). It carries no notion of
    cross-runtime lane position — {!Keeper_turn_driver}'s lane walk
    (which candidate runtime won, and at what index) is tracked
    separately on {!Keeper_turn_driver.named_run_result}. *)

(** {1 Runtime metrics capture} *)

type runtime_metrics_capture
(** Mutable accumulator threaded through AGENT_CORE's per-call
    metrics sink to record per-attempt latency / errors
    and per-fallback events.  Held abstract because
    callers do not pattern-match on the internal
    counter / list state — they construct one via
    {!runtime_metrics_for_candidates}, hand it to AGENT_CORE
    through a direct [Llm_provider.Metrics.t] record, then materialise
    a {!runtime_observation} via
    {!runtime_observation_with_metrics}. *)

val record_attempt_terminal :
  runtime_metrics_capture ->
  model_id:string ->
  latency_ms:int option ->
  error:string option ->
  unit
(** Records one terminal provider attempt in [capture]. This is for
    named-runtime runners that receive provider-attempt completion
    directly but cannot thread AGENT_CORE's per-call metrics sink through the
    provider invocation path. *)

val runtime_metrics_for_candidates :
  unit ->
  runtime_metrics_capture * Llm_provider.Metrics.t
(** Builds the [(capture, metrics)] pair the per-call metrics path consumes.
    Three callbacks write to [capture]: a request start opens an attempt, a
    request end closes it with its latency, an error closes it with the
    message. Two more record the stream's first-chunk and inter-chunk
    timings. The rest are no-ops, and nothing here reaches a metric store --
    the capture is read back by {!runtime_observation_with_metrics} and
    travels as part of the observation. *)

val runtime_observation_with_metrics :
  runtime_id:string ->
  selected_model_raw:string option ->
  capture:runtime_metrics_capture ->
  ?attempt_details_source:string ->
  ?agent_core_internal_runtime_allowed:bool ->
  ?usage_scope:Runtime_usage_scope.t ->
  ?request_context:request_context ->
  unit ->
  runtime_observation
(** Materialises a {!runtime_observation} from a finished
    capture.  [attempts] is flipped into chronological order;
    [attempt_details_source] is set to
    ["agent_core_metrics_callbacks"] to flag that the per-call
    metrics path was wired. *)
