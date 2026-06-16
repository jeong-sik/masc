(** Runtime_observation — runtime observation, metrics
    capture, and a single-actor runtime-counter store.

    The .ml splits into two concerns:
    - {b Runtime observation}: the {!runtime_observation}
      record + companion attempt / fallback events,
      built per-turn in {!Keeper_turn_driver} via the
      {!runtime_metrics_for_candidates} +
      {!runtime_observation_with_metrics} pair.
    - {b Runtime audit actor}: a single-fiber consumer
      ({!start_actor_if_needed}) that drains an
      [Eio.Stream] of {!record_runtime} /
      {!record_fallback_event} requests so concurrent
      callers do not contend on the in-memory counter
      maps.

    Dotted callers ({!Runtime_observation.X}) and the
    runtime-include consumer rely on the surface pinned here.

    Internal helpers stay private at this boundary
    ([runtime_attempt] / [runtime_fallback_event] type
    bodies (exposed as part of {!runtime_observation}'s
    [attempts] / [fallback_events] fields with their full
    record shape),
    [runtime_counter] type, [StringMap],
    [runtime_max_keys], [create_runtime_counter],
    [runtime_eviction] type, [find_runtime_eviction_candidate],
    [display_provider_name_of_config], [strip_latest_suffix],
    [runtime_observation_of_candidates],
    [runtime_attempt_to_json], [runtime_fallback_event_to_json],
    [update_first_attempt_if], [record_attempt_start],
    [ensure_terminal_attempt],
    [runtime_observation_to_json], [get_runtime_audit_store],
    [runtime_outcome_to_string],
    [top_level_reason_of_observation],
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

type runtime_fallback_event = {
  from_model_id : string;
  from_model_label : string option;
  to_model_id : string;
  to_model_label : string option;
  reason : string;
}

type runtime_observation = {
  runtime_id : string;
  strategy : string option;
  configured_labels : string list;
  candidate_models : string list;
  primary_model : string option;
  selected_model : string option;
  selected_model_raw : string option;
  selected_index : int option;
  fallback_hops : int option;
  fallback_applied : bool;
  attempts : runtime_attempt list;
  fallback_events : runtime_fallback_event list;
  attempt_details_available : bool;
  attempt_details_source : string;
  oas_internal_runtime_allowed : bool;
  streaming_ttfrc_ms : float option;
  streaming_inter_chunk_count : int;
  streaming_inter_chunk_avg_ms : float option;
}
(** Per-turn runtime execution snapshot.  [attempts] is
    in chronological order (the internal capture stores
    it reversed and {!runtime_observation_with_metrics}
    flips it on materialise).  [attempt_details_source]
    distinguishes the capture path (the canonical
    [oas_metrics_callbacks] tag vs legacy fallbacks) so
    operators can tell at-a-glance whether the per-call
    metrics sink was wired. *)

(** {1 Provider config helpers} *)

val provider_name_of_config :
  Llm_provider.Provider_config.t -> string
(** Canonical provider slug from a config. Free-form string used as
    the runtime counter key; the function does not enumerate
    specific providers. *)

val model_label_of_config :
  Llm_provider.Provider_config.t -> string
(** Canonical [provider:model] label (e.g.
    ["anthropic:claude-opus"]).  Compatibility helper for legacy
    tests and callers; current public attempt/fallback projections use
    runtime-lane labels instead. *)

(** {1 Runtime metrics capture} *)

type runtime_metrics_capture
(** Mutable accumulator threaded through OAS's per-call
    metrics sink to record per-attempt latency / errors
    and per-fallback events.  Held abstract because
    callers do not pattern-match on the internal
    counter / list state — they construct one via
    {!runtime_metrics_for_candidates}, hand it to OAS
    through a direct [Llm_provider.Metrics.t] record, then materialise
    a {!runtime_observation} via
    {!runtime_observation_with_metrics}. *)

val runtime_attempt_terminal_event_json :
  ?slot_release_at_phase:string ->
  ?productive_phase_elapsed_ms:int ->
  ?retry_phase_elapsed_ms:int ->
  model_id:string ->
  model_label:string option ->
  latency_ms:int option ->
  error:string option ->
  unit ->
  Yojson.Safe.t
(** Builds the structured JSON payload emitted to system_log for one
    runtime candidate's terminal state. Exposed for tests so the shape
    contract (`event`, `model_id`, `model_label`, `latency_ms`, `outcome`,
    `error_message`, `slot_release_at_phase`,
    `productive_phase_elapsed_ms`, `retry_phase_elapsed_ms`) is locked
    against silent drift; downstream operators grep on these field names
    when tracing why a runtime exhausted or why a keeper released its turn
    slot instead of scheduling another degraded retry. *)

val record_attempt_terminal :
  runtime_metrics_capture ->
  model_id:string ->
  latency_ms:int option ->
  error:string option ->
  unit
(** Records one terminal provider attempt in [capture]. This is for
    named-runtime runners that receive provider-attempt completion
    directly but cannot thread OAS's per-call metrics sink through the
    provider invocation path. *)

val runtime_metrics_for_candidates :
  candidate_count:int ->
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
  ?strategy:string ->
  configured_labels:string list ->
  candidate_count:int ->
  selected_model_raw:string option ->
  capture:runtime_metrics_capture ->
  ?attempt_details_source:string ->
  ?oas_internal_runtime_allowed:bool ->
  unit ->
  runtime_observation
(** Materialises a {!runtime_observation} from a finished
    capture.  [attempts] / [fallback_events] are flipped
    into chronological order;
    [attempt_details_source] is set to
    ["oas_metrics_callbacks"] to flag that the per-call
    metrics path was wired. *)

(** {1 Fallback recorder} *)

val record_fallback_event :
  runtime_metrics_capture ->
  from_model:string ->
  to_model:string ->
  reason:string ->
  unit
(** Appends a fallback event to [capture].  The public event keeps the
    historical field names but records runtime-lane labels rather than
    concrete provider/model identities. *)

(** {1 Runtime audit actor} *)

val start_actor_if_needed : sw:Eio.Switch.t -> unit
(** Spawns the single audit-actor fiber under [sw] if it
    has not already been started in the current process.
    Idempotent — a second call is a no-op so the bootstrap
    paths can call it from multiple entry points. *)

val record_runtime :
  ?keeper_name:string ->
  observation:runtime_observation option ->
  runtime_id:string ->
  outcome:[ `Success | `Failure | `Rejected ] ->
  unit ->
  unit
(** Posts a record-runtime message onto the audit stream.
    The actor consumes it asynchronously, bumping the
    per-runtime counters and persisting the audit JSON
    via {!record_runtime_audit}.  Non-blocking — the
    caller does not wait for the actor to drain. *)

val reset_runtime_counters_for_test : unit -> unit
(** Posts a reset message onto the stream.  Test-only
    isolator; no-op outside the actor's lifetime. *)

(** {1 JSON projections (runtime-include consumers)} *)

val runtime_metrics_json : unit -> Yojson.Safe.t
(** Posts a [Get_metrics_json] request to the actor and
    waits on the resulting promise.  Returns the
    aggregated runtime-counter JSON snapshot for the
    operator dashboard.  Pinned because
    [Runtime_agent] re-exposes it via the
    [include Runtime_observation] module. *)

val runtime_observation_to_json :
  runtime_observation -> Yojson.Safe.t
(** Wire encoder for {!runtime_observation} — flattens
    [attempts] / [fallback_events] / outcome metadata
    into a single [`Assoc].  Pinned because the runtime-
    include consumer ([Runtime_agent]) re-exposes it. *)
