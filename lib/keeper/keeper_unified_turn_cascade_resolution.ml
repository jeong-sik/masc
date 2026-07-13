(** Keeper_unified_turn_cascade_resolution — Telemetry-event publishing
    for cascade (retry/rotation) resolution decisions.

    Publishes a [telemetry_event] on the MASC Event_bus each time the
    keeper retry loop resolves a cascade decision type.

    @since task-786 *)

type cascade_decision_kind =
  | Degraded_retry_allowed
  | No_degraded_retry

let decision_kind_to_string : cascade_decision_kind -> string = function
  | Degraded_retry_allowed -> "degraded_retry_allowed"
  | No_degraded_retry -> "no_degraded_retry"

let publish_cascade_resolution
    ~keeper_name
    ~runtime_id
    ~decision
    ~reason
    ~next_runtime
    ~attempt
    ~error_kind
    ~error_message
  =
  let payload = `Assoc
    [ "keeper_name", `String keeper_name
    ; "runtime_id", `String runtime_id
    ; "decision", `String (decision_kind_to_string decision)
    ; "reason", `String reason
    ; "next_runtime",
      (match next_runtime with Some r -> `String r | None -> `Null)
    ; "attempt", `Int attempt
    ; "error_kind",
      (match error_kind with Some k -> `String k | None -> `Null)
    ; "error_message",
      (match error_message with Some m -> `String m | None -> `Null)
    ; "timestamp", `Float (Time_compat.now ())
    ]
  in
  match Masc_event_bus.get () with
  | None ->
    Log.Keeper.debug
      "cascade_resolution: no Masc_event_bus available, skipping telemetry"
  | Some bus ->
    let open Agent_sdk.Event_bus in
    publish bus (mk_event (Custom ("telemetry_event", payload)))
