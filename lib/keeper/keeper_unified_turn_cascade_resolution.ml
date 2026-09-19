(** Keeper_unified_turn_cascade_resolution — Telemetry-event publishing
    for the end of a unified keeper cycle that has no lane candidate left.

    Publishes a [telemetry_event] on the MASC Event_bus with the reason the
    cycle stopped.

    @since task-786 *)

let publish_cascade_resolution
    ~keeper_name
    ~runtime_id
    ~reason
    ~attempt
    ~error_kind
    ~error_message
  =
  let payload = `Assoc
    [ "keeper_name", `String keeper_name
    ; "runtime_id", `String runtime_id
    ; "reason", `String reason
    ; "attempt", `Int attempt
    ; "error_kind",
      (match error_kind with Some k -> `String k | None -> `Null)
    ; "error_message",
      (match error_message with Some m -> `String m | None -> `Null)
    ; "timestamp", `Float (Time_compat.now ())
    ]
  in
  match Event_bus_slots.get_masc () with
  | None ->
    Log.Keeper.debug
      "cascade_resolution: no masc event bus available, skipping telemetry"
  | Some bus ->
    let open Agent_core.Event_bus in
    publish bus (mk_event (Custom ("telemetry_event", payload)))
