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

let tool_start_is_replay existing tool =
  String.equal existing.tool_call_id tool.tool_call_id

let sdk_stream_event_is_deliverable =
  Agent_sdk.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal

let stream_start_is_tool ~index ~content_type ~tool_id ~tool_name =
  sdk_stream_event_is_deliverable
    (Agent_sdk.Types.ContentBlockStart
       { index; content_type; tool_id; tool_name })

let has_any_tool_identity ~tool_id ~tool_name =
  match tool_id, tool_name with
  | None, None -> false
  | _ -> true

let protocol_error ?index ?event_type ?reason ?raw_bytes kind =
  Keeper_chat_events.Oas_stream_protocol_error
    { kind; index; event_type; reason; raw_bytes }

let content_block_start_event ~index ~content_type ~tool_id ~tool_name =
  Keeper_chat_events.Oas_content_block_start
    { index
    ; content_type
    ; tool_call_id = tool_id
    ; tool_call_name = tool_name
    }

let content_block_stop_event ~index =
  Keeper_chat_events.Oas_content_block_stop { index }

let tool_args_event ~redact_text ~snapshot bridge_state index args =
  let open Keeper_chat_events in
  match stream_tool_for_index bridge_state index with
  | Some tool ->
      let args = redact_text args in
      let chat_event =
        if snapshot then
          Tool_call_args_snapshot { tool_call_id = tool.tool_call_id; snapshot = args }
        else Tool_call_args { tool_call_id = tool.tool_call_id; delta = args }
      in
      { bridge_state; chat_events = [ chat_event ] }
  | None ->
      { bridge_state;
        chat_events =
          [ protocol_error ~index
              ~reason:"tool argument event arrived before tool start"
              Tool_args_without_start ]
      }

let translate ~redact_text ~on_text_delta bridge_state
    (evt : Agent_sdk.Types.sse_event) =
  let open Agent_sdk.Types in
  let open Keeper_chat_events in
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
  | ContentBlockDelta { index; delta = ThinkingDelta text } ->
      { bridge_state;
        chat_events =
          [ Oas_thinking_delta { index; delta = redact_text text } ]
      }
  | ContentBlockDelta { index; delta = ThinkingSignatureDelta signature } ->
      { bridge_state;
        chat_events =
          [ Oas_thinking_signature_delta
              { index; signature_bytes = String.length signature } ]
      }
  | ContentBlockDelta
      { index; delta = MediaDelta { media_type; source_type; data } } ->
      { bridge_state;
        chat_events =
          [ Oas_media_delta
              { index; media_type; source_type; bytes = String.length data } ]
      }
  | ContentBlockStart { index; content_type; tool_id; tool_name }
    when stream_start_is_tool ~index ~content_type ~tool_id ~tool_name -> (
      match tool_id, tool_name with
      | Some tid, Some tname
        when String.trim tid <> "" && String.trim tname <> "" ->
      let tool = { tool_call_id = tid; tool_call_name = tname } in
      let existing_tool = stream_tool_for_index bridge_state index in
      let block_start =
        content_block_start_event ~index ~content_type ~tool_id:(Some tid)
          ~tool_name:(Some tname)
      in
      { bridge_state = replace_tool bridge_state index tool;
        chat_events =
          block_start
          :: (match existing_tool with
           | Some existing when tool_start_is_replay existing tool -> []
           | Some existing ->
               [ Tool_call_end { tool_call_id = existing.tool_call_id };
                 Tool_call_start { tool_call_id = tid; tool_call_name = tname } ]
           | None ->
               [ Tool_call_start { tool_call_id = tid; tool_call_name = tname } ])
      }
      | _ ->
          let block_start =
            content_block_start_event ~index ~content_type ~tool_id ~tool_name
          in
          { bridge_state;
            chat_events =
              [ block_start;
                protocol_error ~index
                  ~reason:"tool-use block start missed tool id or name"
                  Tool_start_missing_identity ]
          })
  | ContentBlockStart { index; content_type; tool_id; tool_name } ->
      let block_start =
        content_block_start_event ~index ~content_type ~tool_id ~tool_name
      in
      if has_any_tool_identity ~tool_id ~tool_name then
        { bridge_state;
          chat_events =
            [ block_start;
              protocol_error ~index
                ~reason:"non-tool content block carried tool id or name"
                Tool_start_missing_identity ]
        }
      else { bridge_state; chat_events = [ block_start ] }
  | ContentBlockDelta { index; delta = InputJsonDelta args } ->
      tool_args_event ~redact_text ~snapshot:false bridge_state index args
  | ContentBlockDelta { index; delta = InputJsonSnapshot args } ->
      tool_args_event ~redact_text ~snapshot:true bridge_state index args
  | ContentBlockStop { index } -> (
      let block_stop = content_block_stop_event ~index in
      match stream_tool_for_index bridge_state index with
      | Some tool ->
          { bridge_state = remove_tool bridge_state index;
            chat_events =
              [ block_stop; Tool_call_end { tool_call_id = tool.tool_call_id } ]
          }
      | None ->
          { bridge_state; chat_events = [ block_stop ] })
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
