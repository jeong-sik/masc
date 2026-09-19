(** Keeper_unified_turn_cascade_resolution — Telemetry-event publishing
    for the end of a unified keeper cycle that has no lane candidate left.

    Publishes a [telemetry_event] on the MASC Event_bus each time a unified
    keeper cycle ends without another lane candidate to try, with the reason
    it stopped. Direct [masc_keeper_msg] turns do not publish it.

    [keeper_telemetry_consumer] observes [Custom("telemetry_event", _)]
    on the bus and increments
    [masc_keeper_telemetry_events_consumed_total].

    @since task-786 *)

val publish_cascade_resolution :
  keeper_name:string ->
  runtime_id:string ->
  reason:string ->
  attempt:int ->
  error_kind:string option ->
  error_message:string option ->
  unit
(** Publishes a [telemetry_event] with payload
    [{ keeper_name, runtime_id, reason, attempt, error_kind, error_message,
       timestamp }]. *)
