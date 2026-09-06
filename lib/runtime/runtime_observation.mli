(** Runtime_observation — runtime observation, metrics
    capture, and a single-actor runtime-counter store.

    The .ml splits into two concerns:
    - {b Runtime observation}: the {!runtime_observation}
      record + companion attempts,
      built per-turn in {!Keeper_turn_driver} via the
      {!runtime_metrics_for_candidates} +
      {!runtime_observation_with_metrics} pair.
    - {b Runtime audit actor}: a single-fiber consumer
      ({!start_actor_if_needed}) that drains an
      [Eio.Stream] of [record_runtime] requests so
      concurrent callers do not contend on the in-memory
      counter maps.

    Dotted callers ({!Runtime_observation.X}) and the
    runtime-include consumer rely on the surface pinned here.

    Internal helpers stay private at this boundary
    ([runtime_attempt] type body (exposed as part of
    {!runtime_observation}'s [attempts] field with its full
    record shape),
    [runtime_counter] type, [StringMap],
    [runtime_max_keys], [create_runtime_counter],
    [runtime_eviction] type, [find_runtime_eviction_candidate],
    [runtime_observation_of_candidates],
    [runtime_attempt_to_json],
    [update_first_attempt_if], [record_attempt_start],
    [ensure_terminal_attempt],
    [runtime_observation_to_json], [get_runtime_audit_store],
    [runtime_outcome_to_string],
    [keeper_name_to_json], [runtime_audit_json],
    [record_runtime_audit], [increment_counter],
    [distribution_json], [attempt_model_display],
    [msg], [state] types, the [stream] queue,
    [handle_record], [handle_get_metrics], [run_actor],
    [runtime_metrics_json]). *)

(** {1 Runtime observation types} *)

type runtime_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

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

(** {1 Provider config helpers} *)

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
(** Builds the [(capture, metrics)] pair the per-call
    metrics path consumes.  Wires
    [Llm_metric_bridge.emit_request_latency] and
    [emit_http_status] into the metrics callbacks so the
    Otel_metric_store dashboard does not blackhole captured
    turns (the per-call sink takes precedence over the
    global [Llm_metric_bridge] when both are wired). *)

val runtime_observation_with_metrics :
  runtime_id:string ->
  selected_model_raw:string option ->
  capture:runtime_metrics_capture ->
  ?attempt_details_source:string ->
  ?agent_core_internal_runtime_allowed:bool ->
  ?usage_scope:Runtime_usage_scope.t ->
  unit ->
  runtime_observation
(** Materialises a {!runtime_observation} from a finished
    capture.  [attempts] is flipped into chronological order;
    [attempt_details_source] is set to
    ["agent_core_metrics_callbacks"] to flag that the per-call
    metrics path was wired. *)

(** {1 Runtime audit actor} *)

val start_actor_if_needed : sw:Eio.Switch.t -> unit
(** Spawns the single audit-actor fiber under [sw] if it
    has not already been started in the current process.
    Idempotent — a second call is a no-op so the bootstrap
    paths can call it from multiple entry points. *)


(** {1 JSON projections (runtime-include consumers)} *)

val runtime_metrics_json : unit -> Yojson.Safe.t
(** Posts a [Get_metrics_json] request to the actor and
    waits on the resulting promise.  Returns the
    aggregated runtime-counter JSON snapshot for the
    operator dashboard.  Pinned because
    [Runtime_agent] re-exposes it via the
    [include Runtime_observation] module. *)
