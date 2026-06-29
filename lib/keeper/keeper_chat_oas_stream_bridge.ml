type tool_ref = {
  tool_call_id : string;
  tool_call_name : string;
}

type state = { tools_by_index : (int * tool_ref) list }

type translated_event = {
  bridge_state : state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}

let empty_state = { tools_by_index = [] }

let stream_tool_for_index bridge_state index =
  List.assoc_opt index bridge_state.tools_by_index

let replace_tool bridge_state index tool =
  { tools_by_index =
      (index, tool) :: List.remove_assoc index bridge_state.tools_by_index
  }

let remove_tool bridge_state index =
  { tools_by_index = List.remove_assoc index bridge_state.tools_by_index }

let protocol_error ?index ?event_type ?reason ?raw_bytes kind =
  Keeper_chat_events.Oas_stream_protocol_error
    { kind; index; event_type; reason; raw_bytes }

let translate ~redact_text ~on_text_delta bridge_state
    (evt : Agent_sdk.Types.sse_event) =
  let open Agent_sdk.Types in
  let open Keeper_chat_events in
  let no_events = { bridge_state; chat_events = [] } in
  match evt with
  | Connected ->
      { bridge_state; chat_events = [ Oas_stream_connected ] }
  | MessageStart { id; model; usage } ->
      { bridge_state;
        chat_events =
          [
            Oas_stream_message_start
              { provider_message_id = id; model; usage };
          ]
      }
  | MessageDelta { stop_reason; usage } ->
      { bridge_state;
        chat_events = [ Oas_stream_message_delta { stop_reason; usage } ]
      }
  | MessageStop ->
      { bridge_state; chat_events = [ Oas_stream_message_stop ] }
  | Ping ->
      { bridge_state; chat_events = [ Oas_stream_ping ] }
  | Timeout reason ->
      { bridge_state;
        chat_events =
          [ Event_error { message = redact_text ("Timeout: " ^ reason) } ]
      }
  | ContentBlockDelta { delta = TextDelta text; _ } ->
      { bridge_state; chat_events = [ Text_delta (on_text_delta text) ] }
  | ContentBlockDelta { delta = ThinkingDelta text; _ } ->
      { bridge_state;
        chat_events =
          [ Oas_thinking_delta { delta = redact_text text } ]
      }
  | ContentBlockDelta { delta = ThinkingSignatureDelta signature; _ } ->
      { bridge_state;
        chat_events =
          [ Oas_thinking_signature_delta
              { signature_bytes = String.length signature } ]
      }
  | ContentBlockDelta { delta = MediaDelta { media_type; source_type; data }; _ } ->
      { bridge_state;
        chat_events =
          [ Oas_media_delta
              { media_type; source_type; bytes = String.length data } ]
      }
  | ContentBlockStart { index; tool_id = Some tid; tool_name = Some tname; _ }
    when String.trim tid <> "" && String.trim tname <> "" ->
      let tool = { tool_call_id = tid; tool_call_name = tname } in
      let duplicate_event =
        match stream_tool_for_index bridge_state index with
        | None -> []
        | Some _ ->
            [ protocol_error ~index
                ~reason:"content block start reused an active stream index"
                Tool_start_duplicate_index ]
      in
      { bridge_state = replace_tool bridge_state index tool;
        chat_events =
          duplicate_event
          @ [ Tool_call_start { tool_call_id = tid; tool_call_name = tname } ]
      }
  | ContentBlockStart { index; tool_id; tool_name; _ } ->
      let partial_tool_identity =
        match tool_id, tool_name with
        | None, None -> false
        | _ -> true
      in
      if partial_tool_identity then
        { bridge_state;
          chat_events =
            [ protocol_error ~index
                ~reason:"tool content block start missed tool id or name"
                Tool_start_missing_identity ]
        }
      else no_events
  | ContentBlockDelta { index; delta = InputJsonDelta args } -> (
      match stream_tool_for_index bridge_state index with
      | Some tool ->
          { bridge_state;
            chat_events =
              [ Tool_call_args
                  { tool_call_id = tool.tool_call_id; delta = redact_text args } ]
          }
      | None ->
          { bridge_state;
            chat_events =
              [ protocol_error ~index
                  ~reason:"tool argument delta arrived before tool start"
                  Tool_args_without_start ]
          })
  | ContentBlockStop { index } -> (
      match stream_tool_for_index bridge_state index with
      | Some tool ->
          { bridge_state = remove_tool bridge_state index;
            chat_events = [ Tool_call_end { tool_call_id = tool.tool_call_id } ]
          }
      | None ->
          { bridge_state;
            chat_events =
              [ protocol_error ~index
                  ~reason:"tool block stop arrived before tool start"
                  Tool_stop_without_start ]
          })
  | SSEError { message; error_type; raw = _ } ->
      let reason =
        match error_type with
        | None -> message
        | Some error_type -> error_type ^ ": " ^ message
      in
      { bridge_state;
        chat_events =
          [ protocol_error ?event_type:error_type ~reason:(redact_text message)
              Sse_error;
            Event_error
              { message = redact_text ("Provider stream error: " ^ reason) } ]
      }
  | SSEParseFailed { raw; reason } ->
      { bridge_state;
        chat_events =
          [ protocol_error ~reason:(redact_text reason)
              ~raw_bytes:(String.length raw) Sse_parse_failed;
            Event_error
              { message =
                  redact_text ("Provider stream parse failed: " ^ reason) } ]
      }
  | SSEUnknownEventType { event_type; raw } ->
      { bridge_state;
        chat_events =
          [ protocol_error ~event_type ~raw_bytes:(String.length raw)
              Sse_unknown_event_type ]
      }
  | StreamIncomplete { reason } ->
      { bridge_state;
        chat_events =
          [ protocol_error ~reason:(redact_text reason) Sse_stream_incomplete;
            Event_error
              { message =
                  redact_text ("Provider stream incomplete: " ^ reason) } ]
      }
