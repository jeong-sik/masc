(** Keeper_unified_turn_cascade_resolution — Telemetry-event publishing
    for cascade (retry/rotation) resolution decisions.

    Publishes a [telemetry_event] on the MASC Event_bus each time the
    keeper runtime rotation resolves a cascade decision — degraded retry
    allowed or no degraded retry.

    [keeper_telemetry_consumer] observes [Custom("telemetry_event", _)]
    on the bus and increments
    [masc_keeper_telemetry_events_consumed_total].

    @since task-786 *)

(** {1 Decision kind} *)

type cascade_decision_kind =
  | Degraded_retry_allowed
  | No_degraded_retry
(** Kind of cascade resolution decision. *)

(** {1 Publishing} *)

val publish_cascade_resolution :
  keeper_name:string ->
  runtime_id:string ->
  decision:cascade_decision_kind ->
  reason:string ->
  next_runtime:string option ->
  attempt:int ->
  error_kind:string option ->
  error_message:string option ->
  unit
(** Publishes a [telemetry_event] with payload
    [{ keeper_name, runtime_id, decision, reason, next_runtime,
       attempt, error_kind, error_message, timestamp }].

    Call at each cascade resolution point so observability can track provider
    fallback patterns. *)
