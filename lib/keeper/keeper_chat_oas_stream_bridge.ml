type tool_ref = {
  tool_call_id : string;
  tool_call_name : string;
}

type block_state =
  | Active_tool of tool_ref
  | Invalid_tool_block of { failed_tool_call_id : string option }
  | Active_media of
      { media_type : string
      ; source_type : Agent_sdk.Types.media_source_kind
      ; chunks : string list (* reversed: newest chunk first, concatenated at stop *)
      ; encoded_bytes : int
      }
      (* RFC-0301: model-generated media accumulates here across [MediaDelta]
         chunks and is persisted to {!Keeper_chat_media_store} at the block stop,
         emitting a reader-facing URL instead of a byte count. *)

type state = { blocks_by_index : (int * block_state) list }

type translated_event = {
  bridge_state : state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}

let empty_state = { blocks_by_index = [] }

let stream_block_for_index bridge_state index =
  List.assoc_opt index bridge_state.blocks_by_index

let replace_block bridge_state index block =
  { blocks_by_index =
      (index, block) :: List.remove_assoc index bridge_state.blocks_by_index
  }

let invalidate_block bridge_state index ~failed_tool_call_id =
  replace_block bridge_state index (Invalid_tool_block { failed_tool_call_id })

let remove_block bridge_state index =
  { blocks_by_index = List.remove_assoc index bridge_state.blocks_by_index }

let tool_start_is_replay existing tool =
  String.equal existing.tool_call_id tool.tool_call_id
  && String.equal existing.tool_call_name tool.tool_call_name

let stream_start_is_tool ~index ~content_type ~tool_id ~tool_name =
  Agent_sdk.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal
    (Agent_sdk.Types.ContentBlockStart
       { index; content_type; tool_id; tool_name })

let has_any_tool_identity ~tool_id ~tool_name =
  match tool_id, tool_name with
  | None, None -> false
  | _ -> true

let protocol_error ?index ?tool_call_id ?event_type ?reason ?raw_bytes kind =
  Keeper_chat_events.Oas_stream_protocol_error
    { kind; index; tool_call_id; event_type; reason; raw_bytes }

let media_persist_error_kind = function
  | Keeper_chat_media_store.Unsupported_source_type _ ->
      Keeper_chat_events.Media_source_unsupported
  | Keeper_chat_media_store.Invalid_base64 _ ->
      Keeper_chat_events.Media_decode_failed
  | Keeper_chat_media_store.Media_too_large _ ->
      Keeper_chat_events.Media_payload_too_large
  | Keeper_chat_media_store.Write_failed _ ->
      Keeper_chat_events.Media_persist_failed

let media_payload_too_large_reason ~size_bytes ~max_bytes =
  Printf.sprintf "generated media payload too large: size_bytes=%d max_bytes=%d"
    size_bytes
    max_bytes

let media_persist_protocol_reason = function
  | Keeper_chat_media_store.Write_failed _ -> "failed to persist generated media"
  | err -> Keeper_chat_media_store.persist_error_to_string err

let add_media_chunk ~media_type ~source_type ~chunks ~encoded_bytes data =
  let encoded_bytes = encoded_bytes + String.length data in
  let max_bytes = Keeper_chat_media_store.max_wire_bytes () in
  if encoded_bytes > max_bytes
  then Error (encoded_bytes, max_bytes)
  else Ok (Active_media { media_type; source_type; chunks = data :: chunks; encoded_bytes })

let media_payload_too_large_event ~index ~size_bytes ~max_bytes =
  protocol_error ~index ~raw_bytes:size_bytes
    ~reason:(media_payload_too_large_reason ~size_bytes ~max_bytes)
    Keeper_chat_events.Media_payload_too_large

let finalize_media_block ~redact_text ~base_dir ~index ~media_type ~source_type
    ~chunks ~encoded_bytes =
  let max_wire_bytes = Keeper_chat_media_store.max_wire_bytes () in
  if encoded_bytes > max_wire_bytes
  then
    [ media_payload_too_large_event ~index ~size_bytes:encoded_bytes
        ~max_bytes:max_wire_bytes
    ]
  else
    let data = String.concat "" (List.rev chunks) in
  match
    Keeper_chat_media_store.persist_media_source_result ~base_dir ~media_type
      ~source_type ~data
  with
  | Ok (_token, media_ref) ->
      [ Keeper_chat_events.Oas_media_delta
          { index; media_type; source_type; media_ref }
      ]
  | Error err ->
      [ protocol_error ~index ~raw_bytes:(String.length data)
          ~reason:(redact_text (media_persist_protocol_reason err))
          (media_persist_error_kind err)
      ]

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
  match stream_block_for_index bridge_state index with
  | Some (Active_tool tool) ->
      let args = redact_text args in
      let chat_event =
        if snapshot then
          Tool_call_args_snapshot { tool_call_id = tool.tool_call_id; snapshot = args }
        else Tool_call_args { tool_call_id = tool.tool_call_id; delta = args }
      in
      { bridge_state; chat_events = [ chat_event ] }
  | Some (Invalid_tool_block { failed_tool_call_id }) ->
      { bridge_state;
        chat_events =
          [ protocol_error ?tool_call_id:failed_tool_call_id ~index
              ~reason:"tool argument event arrived after invalid tool block start"
              Tool_args_without_start ]
      }
  | Some (Active_media _) ->
      { bridge_state;
        chat_events =
          [ protocol_error ~index
              ~reason:"tool argument event arrived for a media block"
              Tool_args_without_start ]
      }
  | None ->
      { bridge_state;
        chat_events =
          [ protocol_error ~index
              ~reason:"tool argument event arrived before tool start"
              Tool_args_without_start ]
      }

let translate ~redact_text ~on_text_delta ~base_dir bridge_state
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
      (* Block indices are scoped to one provider message. A keeper dispatch is a
         multi-turn tool loop: each OAS call is a separate stream whose block
         indices restart at 0. Clear the per-message block table at message end
         so the next call's reused index cannot collide with a stale [Active_tool]
         (the cross-message [tool_args_without_start] seen with deepseek-v4-flash
         via ollama_cloud, an OpenAI-compat stream carrying no wire
         content_block_stop). Close any tool block still open here with a
         [Tool_call_end] rather than dropping it silently — with OAS now emitting
         balanced ContentBlockStop the open set is normally already empty. *)
      let block_ends =
        List.concat_map
          (fun (index, block) ->
            match block with
            | Active_tool tool ->
                [ Tool_call_end { tool_call_id = tool.tool_call_id } ]
            | Invalid_tool_block _ -> []
            | Active_media { media_type; source_type; chunks; encoded_bytes } ->
                (* RFC-0301: media block still open at message end (no balanced
                   ContentBlockStop) — persist and surface it rather than drop it
                   silently on the block-table clear below. *)
                finalize_media_block ~redact_text ~base_dir ~index ~media_type
                  ~source_type ~chunks ~encoded_bytes)
          bridge_state.blocks_by_index
      in
      { bridge_state = empty_state;
        chat_events = block_ends @ [ Oas_stream_message_stop ]
      }
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
  | ContentBlockDelta
      { index; delta = ReasoningDetailsDelta { reasoning_content; details } } ->
      (* MiniMax split-reasoning stream (#2347): project the reasoning payload
         through the thinking-delta lane so keepers surface it like other
         provider reasoning. OAS owns the typed text projection. *)
      let text =
        Agent_sdk.Types.reasoning_details_text ~reasoning_content ~details
      in
      { bridge_state;
        chat_events = [ Oas_thinking_delta { index; delta = redact_text text } ]
      }
  | ContentBlockDelta { index; delta = ThinkingSignatureDelta signature } ->
      { bridge_state;
        chat_events =
          [ Oas_thinking_signature_delta
              { index; signature_bytes = String.length signature } ]
      }
  | ContentBlockDelta
      { index; delta = MediaDelta { media_type; source_type; data } } ->
      (* RFC-0301: accumulate the media payload across chunks in the block state;
         the persisted URL is emitted once at the block stop (or at message end if
         the stream never closes the block), not a per-chunk count. *)
      (match stream_block_for_index bridge_state index with
       | Some (Active_media m)
         when String.equal m.media_type media_type && m.source_type = source_type
         ->
           (match
              add_media_chunk ~media_type ~source_type ~chunks:m.chunks
                ~encoded_bytes:m.encoded_bytes data
            with
            | Ok block ->
                { bridge_state = replace_block bridge_state index block; chat_events = [] }
            | Error (size_bytes, max_bytes) ->
                { bridge_state = remove_block bridge_state index;
                  chat_events =
                    [ media_payload_too_large_event ~index ~size_bytes ~max_bytes ]
                })
       | Some (Active_media _) ->
           { bridge_state;
             chat_events =
               [ protocol_error ~index
                   ~reason:"media delta metadata changed for active media block"
                   Media_delta_invalid_block ]
           }
       | Some (Active_tool tool) ->
           { bridge_state;
             chat_events =
               [ protocol_error ~index ~tool_call_id:tool.tool_call_id
                   ~reason:"media delta arrived for an active tool block"
                   Media_delta_invalid_block ]
           }
       | Some (Invalid_tool_block { failed_tool_call_id }) ->
           { bridge_state;
             chat_events =
               [ protocol_error ?tool_call_id:failed_tool_call_id ~index
                   ~reason:"media delta arrived for an invalid tool block"
                   Media_delta_invalid_block ]
           }
       | None ->
           (match
              add_media_chunk ~media_type ~source_type ~chunks:[]
                ~encoded_bytes:0 data
            with
            | Ok block ->
                { bridge_state = replace_block bridge_state index block; chat_events = [] }
            | Error (size_bytes, max_bytes) ->
                { bridge_state;
                  chat_events =
                    [ media_payload_too_large_event ~index ~size_bytes ~max_bytes ]
                }))
  | ContentBlockStart { index; content_type; tool_id; tool_name }
    when stream_start_is_tool ~index ~content_type ~tool_id ~tool_name -> (
      match tool_id, tool_name with
      | Some tid, Some tname
        when String.trim tid <> "" && String.trim tname <> "" ->
      let tool = { tool_call_id = tid; tool_call_name = tname } in
      let existing_block = stream_block_for_index bridge_state index in
      let block_start =
        content_block_start_event ~index ~content_type ~tool_id:(Some tid)
          ~tool_name:(Some tname)
      in
      (match existing_block with
       | Some (Active_tool existing) when tool_start_is_replay existing tool ->
           { bridge_state; chat_events = [ block_start ] }
       | Some (Active_tool existing) ->
           { bridge_state =
               invalidate_block bridge_state index
                 ~failed_tool_call_id:(Some existing.tool_call_id);
             chat_events =
               [ block_start;
                 protocol_error ~index ~tool_call_id:existing.tool_call_id
                   ~reason:
                     (Printf.sprintf
                        "tool-use block index already active: existing tool %s/%s, incoming tool %s/%s"
                        existing.tool_call_id existing.tool_call_name tid tname)
                   Tool_start_duplicate_index ]
           }
       | Some (Invalid_tool_block { failed_tool_call_id }) ->
           { bridge_state;
             chat_events =
               [ block_start;
                 protocol_error ?tool_call_id:failed_tool_call_id ~index
                   ~reason:"tool-use block index already invalid"
                   Tool_start_duplicate_index ]
           }
       | Some (Active_media _) ->
           { bridge_state =
               invalidate_block bridge_state index ~failed_tool_call_id:None;
             chat_events =
               [ block_start;
                 protocol_error ~index
                   ~reason:
                     "tool-use block start arrived for an active media block index"
                   Tool_start_duplicate_index ]
           }
       | None ->
           { bridge_state = replace_block bridge_state index (Active_tool tool);
             chat_events =
               [ block_start;
                 Tool_call_start { tool_call_id = tid; tool_call_name = tname } ]
           })
      | _ ->
          let block_start =
            content_block_start_event ~index ~content_type ~tool_id ~tool_name
          in
          { bridge_state =
              invalidate_block bridge_state index ~failed_tool_call_id:None;
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
        { bridge_state =
            invalidate_block bridge_state index
              ~failed_tool_call_id:(Option.bind tool_id (fun id ->
                   if String.trim id = "" then None else Some id));
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
      match stream_block_for_index bridge_state index with
      | Some (Active_tool tool) ->
          { bridge_state = remove_block bridge_state index;
            chat_events =
              [ block_stop; Tool_call_end { tool_call_id = tool.tool_call_id } ]
          }
      | Some (Invalid_tool_block { failed_tool_call_id }) ->
          { bridge_state = remove_block bridge_state index;
            chat_events =
              [ block_stop;
                protocol_error ?tool_call_id:failed_tool_call_id ~index
                  ~reason:"content block stop arrived for invalid tool block"
                  Tool_stop_without_start ]
          }
      | Some (Active_media { media_type; source_type; chunks; encoded_bytes }) ->
          (* RFC-0301: the media block is complete — concat the accumulated chunks,
             persist to the media store, and emit the reader-facing URL (not a
             byte count). *)
          { bridge_state = remove_block bridge_state index;
            chat_events =
              block_stop
              :: finalize_media_block ~redact_text ~base_dir ~index ~media_type
                   ~source_type ~chunks ~encoded_bytes
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
