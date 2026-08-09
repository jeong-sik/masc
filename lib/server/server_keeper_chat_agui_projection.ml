type t =
  { thread_id : string
  ; run_id : string option
  ; message_id : string option
  }

type custom_event_name =
  | Connected
  | Stream_message_start
  | Stream_message_delta
  | Stream_message_stop
  | Stream_ping
  | Content_block_start
  | Content_block_stop
  | Thinking_delta
  | Thinking_signature_delta
  | Media_delta
  | Stream_protocol_error
  | Queue_request
  | Chat_queued
  | Queued_turn_deferred
  | Continuation_checkpoint
  | External_effect_completed
  | Request_terminal
  | Reply_details

let initial =
  { thread_id = Ag_ui.default_thread_id
  ; run_id = None
  ; message_id = None
  }

let json_opt key value =
  match value with
  | None -> []
  | Some value -> [ key, value ]

let ag_role (role : Keeper_chat_events.role) =
  match role with
  | Keeper_chat_events.User -> Ag_ui.User
  | Keeper_chat_events.Assistant -> Ag_ui.Assistant

let custom_event_name_to_string = function
  | Connected -> "KEEPER_CONNECTED"
  | Stream_message_start -> "KEEPER_STREAM_MESSAGE_START"
  | Stream_message_delta -> "KEEPER_STREAM_MESSAGE_DELTA"
  | Stream_message_stop -> "KEEPER_STREAM_MESSAGE_STOP"
  | Stream_ping -> "KEEPER_STREAM_PING"
  | Content_block_start -> "KEEPER_CONTENT_BLOCK_START"
  | Content_block_stop -> "KEEPER_CONTENT_BLOCK_STOP"
  | Thinking_delta -> "KEEPER_THINKING_DELTA"
  | Thinking_signature_delta -> "KEEPER_THINKING_SIGNATURE_DELTA"
  | Media_delta -> "KEEPER_MEDIA_DELTA"
  | Stream_protocol_error -> "KEEPER_STREAM_PROTOCOL_ERROR"
  | Queue_request -> "KEEPER_QUEUE_REQUEST"
  | Chat_queued -> "KEEPER_CHAT_QUEUED"
  | Queued_turn_deferred -> "KEEPER_QUEUED_TURN_DEFERRED"
  | Continuation_checkpoint -> "KEEPER_CONTINUATION_CHECKPOINT"
  | External_effect_completed -> "KEEPER_EXTERNAL_EFFECT_COMPLETED"
  | Request_terminal -> "KEEPER_REQUEST_TERMINAL"
  | Reply_details -> "KEEPER_REPLY_DETAILS"

let custom ~timestamp ~redact_json state name value =
  Ag_ui.make_event ~timestamp ~thread_id:state.thread_id ~run_id:state.run_id
    ~custom_name:(Some (custom_event_name_to_string name))
    ~custom_value:(Some (redact_json value)) Ag_ui.Custom

let turn_lane_to_json = function
  | Keeper_chat_events.Autonomous_lane -> `String "autonomous"
  | Keeper_chat_events.Chat_lane -> `String "chat"

let request_terminal_status_to_string = function
  | Keeper_chat_events.Deferred -> "deferred"
  | Keeper_chat_events.Queued -> "queued"
  | Keeper_chat_events.Done -> "done"
  | Keeper_chat_events.Error -> "error"
  | Keeper_chat_events.Cancelled -> "cancelled"
  | Keeper_chat_events.Rejected -> "rejected"
  | Keeper_chat_events.Acceptance_uncertain -> "acceptance_uncertain"

let request_terminal_status_ok = function
  | Keeper_chat_events.Deferred
  | Keeper_chat_events.Queued
  | Keeper_chat_events.Done
  | Keeper_chat_events.Acceptance_uncertain -> true
  | Keeper_chat_events.Error
  | Keeper_chat_events.Cancelled
  | Keeper_chat_events.Rejected -> false

let optional_string_json = function
  | None -> `Null
  | Some value -> `String value

let optional_in_flight_fields = function
  | Some { Keeper_chat_events.lane; started_at } ->
      [ "in_flight_lane", turn_lane_to_json lane
      ; "in_flight_started_at", `Float started_at
      ]
  | None -> []

let queue_request_to_json (event : Keeper_chat_events.queue_request) =
  `Assoc
    [ "request_id", `String event.request_id
    ; "destination_type", `String "keeper"
    ; "destination_id", `String event.destination_id
    ; "channel", `String event.channel
    ; "actor_id", optional_string_json event.actor_id
    ; "status", `String "queued"
    ; "modalities", `List (List.map (fun value -> `String value) event.modalities)
    ; "transport", `String "sse"
    ; ( "metadata"
      , `Assoc
          (List.map
             (fun (key, value) -> key, `String value)
             event.metadata) )
    ]

let request_terminal_to_json ~redact_text
    (event : Keeper_chat_events.request_terminal) =
  `Assoc
    ([ "keeper_name", `String event.keeper_name
     ; "status", `String (request_terminal_status_to_string event.status)
     ; "ok", `Bool (request_terminal_status_ok event.status)
     ]
     @ json_opt "request_id"
         (Option.map (fun value -> `String value) event.request_id)
     @ json_opt "message"
         (Option.map (fun value -> `String (redact_text value)) event.message))

let queued_turn_deferred_to_json
    (event : Keeper_chat_events.queued_turn_deferred) =
  `Assoc
    ([ "waiting", `Int event.waiting
     ; "shutdown_operation_id", optional_string_json event.shutdown_operation_id
     ]
     @ optional_in_flight_fields event.in_flight)

let chat_queued_to_json (event : Keeper_chat_events.chat_queued) =
  `Assoc
    ([ "keeper_name", `String event.keeper_name
     ; "status", `String "queued"
     ; "queue", `String "keeper_chat_queue"
     ; "pending_count", `Int event.pending_count
     ; "inflight_count", `Int event.inflight_count
     ; "recovery_required_count", `Int event.recovery_required_count
     ; "chat_waiting", `Bool event.chat_waiting
     ; "receipt_id", `String event.receipt_id
     ; "queue_revision", `String (Int64.to_string event.queue_revision)
     ; "shutdown_operation_id", optional_string_json event.shutdown_operation_id
     ]
     @ optional_in_flight_fields event.in_flight)

let reply_details_to_json ~redact_text
    (event : Keeper_chat_events.reply_details) =
  `Assoc
    [ "reply", `String (redact_text event.reply)
    ; "turn_outcome", `String (Keeper_turn_outcome.to_label event.turn_outcome)
    ; "turn_ref", `String (Ids.Turn_ref.to_string event.turn_ref)
    ]

let continuation_checkpoint_to_json ~redact_text
    (event : Keeper_chat_events.continuation_checkpoint) =
  `Assoc
    ([ "message", `String (redact_text event.message) ]
     @ json_opt "request_id"
         (Option.map (fun value -> `String value) event.request_id))

let project ~timestamp ~redact_text ~redact_json state event =
  let open Keeper_chat_events in
  match event with
  | Run_started { run_id; thread_id } ->
      let state = { state with thread_id; run_id = Some run_id } in
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id ~run_id:(Some run_id)
             Ag_ui.Run_started) )
  | Text_message_start { message_id; role } ->
      let state = { state with message_id = Some message_id } in
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~message_id:(Some message_id)
             ~role:(Some (ag_role role)) Ag_ui.Text_message_start) )
  | Text_delta delta ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~message_id:state.message_id
             ~delta:(Some delta) Ag_ui.Text_message_content) )
  | Text_message_end ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~message_id:state.message_id
             Ag_ui.Text_message_end) )
  | External_effect_completed ->
      state, Some (custom ~timestamp ~redact_json state External_effect_completed `Null)
  | Agent_core_stream_connected ->
      state, Some (custom ~timestamp ~redact_json state Connected `Null)
  | Agent_core_stream_message_start { provider_message_id; model; usage } ->
      let value =
        `Assoc
          ([ "provider_message_id", `String provider_message_id
           ; "model", `String model
           ]
           @ json_opt "usage" (Option.map api_usage_to_json usage))
      in
      state, Some (custom ~timestamp ~redact_json state Stream_message_start value)
  | Agent_core_stream_message_delta { stop_reason; usage } ->
      let value =
        `Assoc
          (json_opt "stop_reason"
             (Option.map
                (fun reason ->
                   `String (Agent_core.Types.stop_reason_to_string reason))
                stop_reason)
           @ json_opt "usage" (Option.map api_usage_to_json usage))
      in
      state, Some (custom ~timestamp ~redact_json state Stream_message_delta value)
  | Agent_core_stream_message_stop ->
      state, Some (custom ~timestamp ~redact_json state Stream_message_stop `Null)
  | Agent_core_stream_ping ->
      state, Some (custom ~timestamp ~redact_json state Stream_ping `Null)
  | Agent_core_content_block_start
      { index; content_type; tool_call_id; tool_call_name } ->
      let value =
        `Assoc
          ([ "index", `Int index
           ; "content_type", `String content_type
           ]
           @ json_opt "tool_call_id"
               (Option.map (fun value -> `String value) tool_call_id)
           @ json_opt "tool_call_name"
               (Option.map (fun value -> `String value) tool_call_name))
      in
      state, Some (custom ~timestamp ~redact_json state Content_block_start value)
  | Agent_core_content_block_stop { index } ->
      state, Some (custom ~timestamp ~redact_json state Content_block_stop
                     (`Assoc [ "index", `Int index ]))
  | Agent_core_thinking_delta { index; delta } ->
      state, Some (custom ~timestamp ~redact_json state Thinking_delta
                     (`Assoc [ "index", `Int index; "delta", `String delta ]))
  | Agent_core_thinking_signature_delta { index; signature_bytes } ->
      state, Some (custom ~timestamp ~redact_json state Thinking_signature_delta
                     (`Assoc
                        [ "index", `Int index
                        ; "signature_bytes", `Int signature_bytes
                        ]))
  | Agent_core_media_delta { index; media_type; source_type; media_ref } ->
      state, Some (custom ~timestamp ~redact_json state Media_delta
                     (`Assoc
                        [ "index", `Int index
                        ; "media_type", `String media_type
                        ; ( "source_type"
                          , `String
                              (Agent_core.Types.media_source_kind_to_string
                                 source_type) )
                        ; "media_ref", `String media_ref
                        ]))
  | Agent_core_stream_protocol_error error ->
      state, Some (custom ~timestamp ~redact_json state Stream_protocol_error
                     (stream_protocol_error_to_json error))
  | Queue_request event ->
      state, Some (custom ~timestamp ~redact_json state Queue_request
                     (queue_request_to_json event))
  | Request_terminal event ->
      state, Some (custom ~timestamp ~redact_json state Request_terminal
                     (request_terminal_to_json ~redact_text event))
  | Queued_turn_deferred event ->
      state, Some (custom ~timestamp ~redact_json state Queued_turn_deferred
                     (queued_turn_deferred_to_json event))
  | Chat_queued event ->
      state, Some (custom ~timestamp ~redact_json state Chat_queued
                     (chat_queued_to_json event))
  | Reply_details event ->
      state, Some (custom ~timestamp ~redact_json state Reply_details
                     (reply_details_to_json ~redact_text event))
  | Continuation_checkpoint event ->
      state, Some (custom ~timestamp ~redact_json state Continuation_checkpoint
                     (continuation_checkpoint_to_json ~redact_text event))
  | Tool_call_start { tool_call_id; tool_call_name } ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~tool_call_id:(Some tool_call_id)
             ~tool_call_name:(Some tool_call_name) Ag_ui.Tool_call_start) )
  | Tool_call_args { tool_call_id; delta } ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~tool_call_id:(Some tool_call_id)
             ~delta:(Some delta) Ag_ui.Tool_call_args) )
  | Tool_call_args_snapshot { tool_call_id; snapshot } ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~tool_call_id:(Some tool_call_id)
             ~snapshot:(Some (`String snapshot)) Ag_ui.Tool_call_args) )
  | Tool_call_end { tool_call_id } ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~tool_call_id:(Some tool_call_id)
             Ag_ui.Tool_call_end) )
  | Link_block _
  | Image_block _
  | Status_block _
  | Audio_block _
  | Tool_context_block _ -> state, None
  | Event_error { message } ->
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:state.run_id ~message:(Some (redact_text message))
             Ag_ui.Run_error) )
  | Run_finished { run_id } ->
      let state = { state with run_id = Some run_id } in
      ( state
      , Some
          (Ag_ui.make_event ~timestamp ~thread_id:state.thread_id
             ~run_id:(Some run_id) Ag_ui.Run_finished) )

let is_terminal = function
  | Keeper_chat_events.Event_error _
  | Keeper_chat_events.Run_finished _ -> true
  | _ -> false
