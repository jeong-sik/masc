(** Oas_worker_cascade — cascade observation, metrics
    capture, and a single-actor cascade-counter store.

    The .ml is 685 lines.  Splits into three concerns:
    - {b Worker tuning constants}
      ([default_temperature], [worker_temperature],
      [worker_top_p], [worker_top_k],
      [worker_max_tool_calls_per_turn]) consumed by
      {!Worker_container.build_resume_config} and the
      OAS-named worker path.
    - {b Cascade observation}: the {!cascade_observation}
      record + companion attempt / fallback events,
      built per-turn in {!Oas_worker_named} via the
      {!cascade_metrics_for_candidates} +
      {!cascade_observation_with_metrics} pair.
    - {b Cascade audit actor}: a single-fiber consumer
      ({!start_actor_if_needed}) that drains an
      [Eio.Stream] of {!record_cascade} /
      {!record_fallback_event} requests so concurrent
      callers do not contend on the in-memory counter
      maps.

    Sister facade {!Oas_worker} does
    [include Oas_worker_cascade] to re-expose the constants
    + observation type at the package boundary; this .mli
    therefore pins the surface that
    {!Oas_worker_cascade.X} dotted callers and the
    cascade-include consumer both rely on.

    Internal helpers stay private at this boundary
    ([cascade_attempt] / [cascade_fallback_event] type
    bodies (exposed as part of {!cascade_observation}'s
    [attempts] / [fallback_events] fields with their full
    record shape),
    [cascade_counter] type, [StringMap], [worker_min_p],
    [cascade_max_keys], [create_cascade_counter],
    [cascade_eviction] type, [find_cascade_eviction_candidate],
    [display_provider_name_of_config],
    [model_label_option_of_model_id], [strip_latest_suffix],
    [selected_index_of_model], [normalized_selected_model],
    [cascade_observation_of_candidates],
    [cascade_attempt_to_json], [cascade_fallback_event_to_json],
    [update_first_attempt_if], [record_attempt_start],
    [ensure_terminal_attempt],
    [cascade_observation_to_json], [get_cascade_audit_store],
    [cascade_outcome_to_string],
    [top_level_reason_of_observation],
    [keeper_name_to_json], [cascade_audit_json],
    [record_cascade_audit], [increment_counter],
    [distribution_json], [attempt_model_display],
    [msg], [state] types, the [stream] queue,
    [handle_record], [handle_get_metrics], [run_actor],
    [cascade_metrics_json]). *)

(** {1 Worker tuning constants} *)

val default_temperature : float
val default_max_tokens : int
val deterministic_temperature : float

val worker_temperature : float
val worker_top_p : float
val worker_top_k : int
val worker_max_tool_calls_per_turn : int

(** {1 Cascade observation types} *)

type cascade_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

type cascade_fallback_event = {
  from_model_id : string;
  from_model_label : string option;
  to_model_id : string;
  to_model_label : string option;
  reason : string;
}

type cascade_observation = {
  cascade_name : string;
  strategy : string option;
  configured_labels : string list;
  candidate_models : string list;
  primary_model : string option;
  selected_model : string option;
  selected_model_raw : string option;
  selected_index : int option;
  fallback_hops : int option;
  fallback_applied : bool;
  attempts : cascade_attempt list;
  fallback_events : cascade_fallback_event list;
  attempt_details_available : bool;
  attempt_details_source : string;
}
(** Per-turn cascade execution snapshot.  [attempts] is
    in chronological order (the internal capture stores
    it reversed and {!cascade_observation_with_metrics}
    flips it on materialise).  [attempt_details_source]
    distinguishes the capture path (the canonical
    [oas_metrics_callbacks] tag vs legacy fallbacks) so
    operators can tell at-a-glance whether the per-call
    metrics sink was wired. *)

(** {1 Provider config helpers} *)

val provider_name_of_config :
  Llm_provider.Provider_config.t -> string
(** Canonical provider slug from a config (e.g.
    ["anthropic"] / ["openai"]).  Used as the cascade
    counter key. *)

val model_label_of_config :
  Llm_provider.Provider_config.t -> string
(** Canonical [provider:model] label (e.g.
    ["anthropic:claude-opus-4.7"]).  Used in attempt
    rows + fallback event labels. *)

(** {1 Cascade metrics capture} *)

type cascade_metrics_capture
(** Mutable accumulator threaded through OAS's per-call
    metrics sink to record per-attempt latency / errors
    and per-fallback events.  Held abstract because
    callers do not pattern-match on the internal
    counter / list state — they construct one via
    {!cascade_metrics_for_candidates}, hand it to OAS
    through [Oas_compat.Metrics.make], then materialise
    a {!cascade_observation} via
    {!cascade_observation_with_metrics}. *)

val cascade_metrics_for_candidates :
  candidate_cfgs:Llm_provider.Provider_config.t list ->
  unit ->
  cascade_metrics_capture * Llm_provider.Metrics.t
(** Builds the [(capture, metrics)] pair the per-call
    metrics path consumes.  Wires
    [Llm_metric_bridge.emit_request_latency] and
    [emit_http_status] into the metrics callbacks so the
    Prometheus dashboard does not blackhole captured
    turns (the per-call sink takes precedence over the
    global [Llm_metric_bridge] when both are wired). *)

val cascade_observation_with_metrics :
  cascade_name:string ->
  ?strategy:string ->
  configured_labels:string list ->
  candidate_cfgs:Llm_provider.Provider_config.t list ->
  selected_model_raw:string option ->
  capture:cascade_metrics_capture ->
  unit ->
  cascade_observation
(** Materialises a {!cascade_observation} from a finished
    capture.  [attempts] / [fallback_events] are flipped
    into chronological order;
    [attempt_details_source] is set to
    ["oas_metrics_callbacks"] to flag that the per-call
    metrics path was wired. *)

(** {1 Fallback recorder} *)

val record_fallback_event :
  cascade_metrics_capture ->
  candidate_cfgs:Llm_provider.Provider_config.t list ->
  from_model:string ->
  to_model:string ->
  reason:string ->
  unit
(** Appends a fallback event to [capture].  Resolves the
    [from] / [to] model labels via [candidate_cfgs] so
    the recorded entry carries both the provider id and
    the canonical label (the dashboard renders the
    label, the structured logs key on the id). *)

(** {1 Cascade audit actor} *)

val start_actor_if_needed : sw:Eio.Switch.t -> unit
(** Spawns the single audit-actor fiber under [sw] if it
    has not already been started in the current process.
    Idempotent — a second call is a no-op so the bootstrap
    paths can call it from multiple entry points. *)

val record_cascade :
  ?keeper_name:string ->
  observation:cascade_observation option ->
  cascade_name:string ->
  outcome:[ `Success | `Failure | `Rejected ] ->
  unit ->
  unit
(** Posts a record-cascade message onto the audit stream.
    The actor consumes it asynchronously, bumping the
    per-cascade counters and persisting the audit JSON
    via {!record_cascade_audit}.  Non-blocking — the
    caller does not wait for the actor to drain. *)

val reset_cascade_counters_for_test : unit -> unit
(** Posts a reset message onto the stream.  Test-only
    isolator; no-op outside the actor's lifetime. *)

(** {1 JSON projections (cascade-include consumers)} *)

val cascade_metrics_json : unit -> Yojson.Safe.t
(** Posts a [Get_metrics_json] request to the actor and
    waits on the resulting promise.  Returns the
    aggregated cascade-counter JSON snapshot for the
    operator dashboard.  Pinned because
    [lib/oas_worker.mli] re-exposes it via the
    [include Oas_worker_cascade] cascade. *)

val cascade_observation_to_json :
  cascade_observation -> Yojson.Safe.t
(** Wire encoder for {!cascade_observation} — flattens
    [attempts] / [fallback_events] / outcome metadata
    into a single [`Assoc].  Pinned because the cascade-
    include consumer ([oas_worker.mli]) re-exposes it. *)
