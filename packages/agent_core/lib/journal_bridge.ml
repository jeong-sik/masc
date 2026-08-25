(** Bridge Durable_event journal events to Event_bus.

    Provides an [on_append] callback factory that projects each
    {!Durable_event.event} onto {!Event_bus.Custom} with a stable
    [durable.<kind>] name.  This lets existing Event_bus subscribers
    observe the full journal stream without any Event_bus payload
    schema changes.

    Typical use:
    {[
      let journal =
        Durable_event.create ~on_append:(Journal_bridge.make ~bus ()) ()
      in
      ...
    ]}

    @since 0.133.0 *)

let projection_of_event (evt : Durable_event.event) : string * Yojson.Safe.t =
  match evt with
  | Turn_started { turn; timestamp } ->
    "durable.turn_started", `Assoc [ "turn", `Int turn; "timestamp", `Float timestamp ]
  | Llm_request { turn; model; timestamp } ->
    ( "durable.llm_request"
    , `Assoc [ "turn", `Int turn; "model", `String model; "timestamp", `Float timestamp ]
    )
  | Llm_response
      { turn; input_tokens; output_tokens; stop_reason; duration_ms; timestamp } ->
    ( "durable.llm_response"
    , `Assoc
        [ "turn", `Int turn
        ; "input_tokens", Option.fold ~none:`Null ~some:(fun n -> `Int n) input_tokens
        ; "output_tokens", Option.fold ~none:`Null ~some:(fun n -> `Int n) output_tokens
        ; "stop_reason", `String stop_reason
        ; "duration_ms", `Float duration_ms
        ; "timestamp", `Float timestamp
        ] )
  | Tool_called { turn; tool_name; idempotency_key; input_hash; timestamp } ->
    ( "durable.tool_called"
    , `Assoc
        [ "turn", `Int turn
        ; "tool_name", `String tool_name
        ; "idempotency_key", `String idempotency_key
        ; "input_hash", `String input_hash
        ; "timestamp", `Float timestamp
        ] )
  | Tool_completed
      { turn; tool_name; idempotency_key; output_json; is_error; duration_ms; timestamp }
    ->
    ( "durable.tool_completed"
    , `Assoc
        [ "turn", `Int turn
        ; "tool_name", `String tool_name
        ; "idempotency_key", `String idempotency_key
        ; "output_json", output_json
        ; "is_error", `Bool is_error
        ; "duration_ms", `Float duration_ms
        ; "timestamp", `Float timestamp
        ] )
  | State_transition { from_state; to_state; reason; timestamp } ->
    ( "durable.state_transition"
    , `Assoc
        [ "from_state", `String from_state
        ; "to_state", `String to_state
        ; "reason", `String reason
        ; "timestamp", `Float timestamp
        ] )
  | Checkpoint_saved { checkpoint_id; timestamp } ->
    ( "durable.checkpoint_saved"
    , `Assoc [ "checkpoint_id", `String checkpoint_id; "timestamp", `Float timestamp ] )
  | Error_occurred { turn; error_domain; detail; timestamp } ->
    ( "durable.error_occurred"
    , `Assoc
        [ "turn", `Int turn
        ; "error_domain", `String error_domain
        ; "detail", `String detail
        ; "timestamp", `Float timestamp
        ] )
;;

let make_with_publish ~publish ~bus ?correlation_id ?run_id () =
  fun evt ->
  let name, payload = projection_of_event evt in
  publish bus (Event_bus.mk_event ?correlation_id ?run_id (Custom (name, payload)))
;;

let make = make_with_publish ~publish:Event_bus.publish

let%test "publication failure reaches Durable_event.append after commit" =
  let callback =
    make_with_publish
      ~publish:(fun _bus _event -> raise Exit)
      ~bus:(Event_bus.create ())
      ()
  in
  let journal = Durable_event.create ~on_append:callback () in
  let event = Durable_event.Turn_started { turn = 1; timestamp = 0.0 } in
  match Durable_event.append journal event with
  | Error { exception_ = Exit; _ } -> Durable_event.length journal = 1
  | Ok () | Error _ -> false
;;

let%test "reserved publication failure propagates after commit" =
  let callback =
    make_with_publish
      ~publish:(fun _bus _event -> raise Sys.Break)
      ~bus:(Event_bus.create ())
      ()
  in
  let journal = Durable_event.create ~on_append:callback () in
  let event = Durable_event.Turn_started { turn = 1; timestamp = 0.0 } in
  match Durable_event.append journal event with
  | Ok () | Error _ -> false
  | exception Sys.Break -> Durable_event.length journal = 1
;;
