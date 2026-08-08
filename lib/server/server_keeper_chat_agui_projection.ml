type t =
  { thread_id : string
  ; run_id : string option
  ; message_id : string option
  }

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

let custom ~timestamp ~redact_json state name value =
  Ag_ui.make_event ~timestamp ~thread_id:state.thread_id ~run_id:state.run_id
    ~custom_name:(Some name) ~custom_value:(Some (redact_json value)) Ag_ui.Custom

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
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_EXTERNAL_EFFECT_COMPLETED" `Null)
  | Oas_stream_connected ->
      state, Some (custom ~timestamp ~redact_json state "KEEPER_CONNECTED" `Null)
  | Oas_stream_message_start { provider_message_id; model; usage } ->
      let value =
        `Assoc
          ([ "provider_message_id", `String provider_message_id
           ; "model", `String model
           ]
           @ json_opt "usage" (Option.map api_usage_to_json usage))
      in
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_STREAM_MESSAGE_START" value)
  | Oas_stream_message_delta { stop_reason; usage } ->
      let value =
        `Assoc
          (json_opt "stop_reason"
             (Option.map
                (fun reason ->
                   `String (Agent_sdk.Types.stop_reason_to_string reason))
                stop_reason)
           @ json_opt "usage" (Option.map api_usage_to_json usage))
      in
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_STREAM_MESSAGE_DELTA" value)
  | Oas_stream_message_stop ->
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_STREAM_MESSAGE_STOP" `Null)
  | Oas_stream_ping ->
      state, Some (custom ~timestamp ~redact_json state "KEEPER_STREAM_PING" `Null)
  | Oas_content_block_start
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
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_CONTENT_BLOCK_START" value)
  | Oas_content_block_stop { index } ->
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_CONTENT_BLOCK_STOP"
                     (`Assoc [ "index", `Int index ]))
  | Oas_thinking_delta { index; delta } ->
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_THINKING_DELTA"
                     (`Assoc [ "index", `Int index; "delta", `String delta ]))
  | Oas_thinking_signature_delta { index; signature_bytes } ->
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_THINKING_SIGNATURE_DELTA"
                     (`Assoc
                        [ "index", `Int index
                        ; "signature_bytes", `Int signature_bytes
                        ]))
  | Oas_media_delta { index; media_type; source_type; media_ref } ->
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_MEDIA_DELTA"
                     (`Assoc
                        [ "index", `Int index
                        ; "media_type", `String media_type
                        ; ( "source_type"
                          , `String
                              (Agent_sdk.Types.media_source_kind_to_string
                                 source_type) )
                        ; "media_ref", `String media_ref
                        ]))
  | Oas_stream_protocol_error error ->
      state, Some (custom ~timestamp ~redact_json state
                     "KEEPER_STREAM_PROTOCOL_ERROR"
                     (stream_protocol_error_to_json error))
  | Custom { name; value } ->
      state, Some (custom ~timestamp ~redact_json state name value)
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
