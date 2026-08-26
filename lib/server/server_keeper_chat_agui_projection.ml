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
  | Continuation_checkpoint
  | External_effect_completed
  | Reply_details
  | Tool_approval_requested
  | Tool_approval_settled
  | Tool_result_ready

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
  | Continuation_checkpoint -> "KEEPER_CONTINUATION_CHECKPOINT"
  | External_effect_completed -> "KEEPER_EXTERNAL_EFFECT_COMPLETED"
  | Reply_details -> "KEEPER_REPLY_DETAILS"
  | Tool_approval_requested -> "KEEPER_TOOL_APPROVAL_REQUESTED"
  | Tool_approval_settled -> "KEEPER_TOOL_APPROVAL_SETTLED"
  | Tool_result_ready -> "KEEPER_TOOL_RESULT_READY"

let custom ~timestamp ~redact_json state name value =
  Ag_ui.make_event ~timestamp ~thread_id:state.thread_id ~run_id:state.run_id
    ~custom_name:(Some (custom_event_name_to_string name))
    ~custom_value:(Some (redact_json value)) Ag_ui.Custom

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
  | External_effect_completed { target } ->
      (* A typed target names the real destination so the dashboard stops
         assuming an external connector (#28374). *)
      let value =
        `Assoc [ "target", Keeper_surface_post.delivery_target_to_yojson target ]
      in
      state, Some (custom ~timestamp ~redact_json state External_effect_completed value)
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
           @ json_opt "usage" (Option.map delta_usage_to_json usage))
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
  | Tool_approval_requested { tool_call_id; tool_call_name; args; question; because } ->
      ( state
      , Some
          (custom ~timestamp ~redact_json state Tool_approval_requested
             (`Assoc
                [ ("tool_call_id", `String tool_call_id)
                ; ("tool_call_name", `String tool_call_name)
                ; ("args", `String args)
                ; ("question", `String question)
                ; ("because", `String because)
                ])) )
  | Tool_approval_settled { tool_call_id; outcome } ->
      ( state
      , Some
          (custom ~timestamp ~redact_json state Tool_approval_settled
             (`Assoc
                [ "tool_call_id", `String tool_call_id
                ; "outcome", `String outcome
                ])) )
  | Tool_result_ready { tool_call_id } ->
      ( state
      , Some
          (custom ~timestamp ~redact_json state Tool_result_ready
             (`Assoc [ "tool_call_id", `String tool_call_id ])) )
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
