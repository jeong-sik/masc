(** Per-(provider,model) health aggregator consumed by keeper lifecycle.

    OAS emits [Agent_sdk.Telemetry_event.t] variants; this module maintains
    EWMA state and answers [is_healthy] queries.  All state is process-local. *)

type health = {
  ttfrc_ms_ewma : float;
  timeout_count_5m : int;
  prefill_ms_ewma : float;
  last_updated : float;
}

type config = {
  ttfrc_degraded_ms : float;
  ttfrc_unhealthy_ms : float;
  timeout_count_5m_unhealthy : int;
  prefill_degraded_ms : float;
}

val default_config : config

val set_config : config -> unit
val get_config : unit -> config

val update_from_event : Agent_sdk.Telemetry_event.t -> unit

(** [is_healthy ~provider ~model] returns [false] when the provider is
    known-unhealthy (timeout budget exceeded or TTFR EWMA above threshold).
    Returns [true] when no data exists or the window is stale. *)
val is_healthy : provider:string -> model:string -> bool

(** [is_any_unhealthy_for_model ~model] returns [true] if any provider
    serving [model] is known-unhealthy.  Used when the exact provider
    is not yet resolved (e.g. livelock gate before turn dispatch). *)
val is_any_unhealthy_for_model : model:string -> bool

val get_health : provider:string -> model:string -> health option

(** Reset all in-memory state.  Public for the test harness. *)
val reset_for_tests : unit -> unit
