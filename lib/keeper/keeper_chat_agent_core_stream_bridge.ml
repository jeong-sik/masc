type tool_ref = {
  occurrence : Keeper_chat_events.tool_stream_occurrence;
  tool_call_id : string option;
  tool_call_name : string;
  args_fragments : string list;
}

type block_state =
  | Active_tool of tool_ref
  | Occupied_non_tool_block
  | Invalid_tool_block of
      { failed_tool_call_id : string option
      ; quarantined_occurrence : Keeper_chat_events.tool_stream_occurrence option
      ; quarantine_kind : Keeper_chat_events.stream_protocol_error_kind option
      }
  | Invalid_media_block
  | Active_media of
      { media_type : string
      ; source_type : Agent_core.Types.media_source_kind
      ; chunks : string list (* reversed: newest chunk first, concatenated at stop *)
      ; encoded_bytes : int
      }
      (* RFC-0301: model-generated media accumulates here across [MediaDelta]
         chunks and is persisted to {!Keeper_chat_media_store} at the block stop,
         emitting a reader-facing URL instead of a byte count. *)

type stream_phase =
  | Accepting_content
  | Stop_reason_seen of Agent_core.Types.stop_reason
  | Message_stopped

type tool_quarantine =
  { occurrence : Keeper_chat_events.tool_stream_occurrence
  ; kind : Keeper_chat_events.stream_protocol_error_kind
  }

type state =
  { blocks_by_index : (int * block_state) list
  ; current_stream_scope : int option
  ; stream_phase : stream_phase
  ; scope_failure :
      (Keeper_chat_events.stream_protocol_error_kind * string) option
  ; current_message_has_text : bool
  ; last_completed_message_has_text : bool
  ; message_open : bool
  ; current_provider_message_id : string option
  ; current_message_start :
      (string * string * Agent_core.Types.api_usage option) option
  ; finalized_tools : tool_ref list
  ; tool_quarantines : tool_quarantine list
  ; max_wire_bytes : int
        (* Read once per stream. [Keeper_chat_media_store.max_wire_bytes]
           resolves an env var on every call, so reading it again at finalize
           could reject a payload the chunk path had already accepted, from an
           operator edit landing mid-stream (#24018). *)
  }

type translated_event = {
  bridge_state : state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}

let diagnostic_provider_id = function
  | Some provider_id -> provider_id
  | None -> "<provider-id-absent>"
;;

let empty_state () =
  { blocks_by_index = []
  ; current_stream_scope = None
  ; stream_phase = Accepting_content
  ; scope_failure = None
  ; current_message_has_text = false
  ; last_completed_message_has_text = false
  ; message_open = false
  ; current_provider_message_id = None
  ; current_message_start = None
  ; finalized_tools = []
  ; tool_quarantines = []
  ; max_wire_bytes = Keeper_chat_media_store.max_wire_bytes ()
  }

let reset_runtime_attempt_state state =
  { state with
    blocks_by_index = []
  ; current_stream_scope = None
  ; stream_phase = Accepting_content
  ; scope_failure = None
  ; current_message_has_text = false
  ; last_completed_message_has_text = false
  ; message_open = false
  ; current_provider_message_id = None
  ; current_message_start = None
  }
;;

let enter_stream_scope state stream_scope =
  match state.current_stream_scope with
  | Some current when current = stream_scope -> state
  | None -> { state with current_stream_scope = Some stream_scope }
  | Some _ ->
    { state with
      blocks_by_index = []
    ; current_stream_scope = Some stream_scope
    ; stream_phase = Accepting_content
    ; scope_failure = None
    ; current_message_has_text = false
    ; message_open = false
    ; current_provider_message_id = None
    ; current_message_start = None
    }
;;

let terminal_message_had_text state =
  if state.message_open
  then state.current_message_has_text
  else state.last_completed_message_has_text

let stream_block_for_index bridge_state index =
  List.assoc_opt index bridge_state.blocks_by_index

let replace_block bridge_state index block =
  { bridge_state with
    blocks_by_index =
      (index, block) :: List.remove_assoc index bridge_state.blocks_by_index
  }

let invalidate_block ?quarantined_occurrence ?quarantine_kind bridge_state index
    ~failed_tool_call_id =
  replace_block bridge_state index
    (Invalid_tool_block
       { failed_tool_call_id; quarantined_occurrence; quarantine_kind })

let invalidate_media_block bridge_state index =
  replace_block bridge_state index Invalid_media_block

let remove_block bridge_state index =
  { bridge_state with
    blocks_by_index = List.remove_assoc index bridge_state.blocks_by_index
  }

let occupy_non_tool_index bridge_state index =
  match stream_block_for_index bridge_state index with
  | None -> replace_block bridge_state index Occupied_non_tool_block
  | Some _ -> bridge_state

let tool_start_is_replay existing tool =
  Option.equal String.equal existing.tool_call_id tool.tool_call_id
  && String.equal existing.tool_call_name tool.tool_call_name

let append_tool_args ~snapshot tool args =
  { tool with
    args_fragments = if snapshot then [ args ] else args :: tool.args_fragments
  }

let same_occurrence
    (left : Keeper_chat_events.tool_stream_occurrence)
    (right : Keeper_chat_events.tool_stream_occurrence) =
  Int.equal left.Keeper_chat_events.stream_scope right.stream_scope
  && Int.equal left.block_index right.block_index

let occurrence_is_quarantined state occurrence =
  List.exists
    (fun { occurrence = recorded; kind = _ } ->
       same_occurrence recorded occurrence)
    state.tool_quarantines
  || List.exists
       (fun (_, block) ->
          match block with
          | Invalid_tool_block { quarantined_occurrence = Some recorded; _ } ->
            same_occurrence recorded occurrence
          | Active_tool _
          | Occupied_non_tool_block
          | Invalid_tool_block { quarantined_occurrence = None; _ }
          | Invalid_media_block
          | Active_media _ -> false)
       state.blocks_by_index
;;

let first_quarantine_kind state occurrence =
  match
    List.find_opt
      (fun quarantine -> same_occurrence quarantine.occurrence occurrence)
      state.tool_quarantines
  with
  | Some quarantine -> Some quarantine.kind
  | None ->
    List.find_map
      (fun (_, block) ->
         match block with
         | Invalid_tool_block
             { quarantined_occurrence = Some recorded
             ; quarantine_kind = Some kind
             ; _
             }
           when same_occurrence recorded occurrence -> Some kind
         | Active_tool _
         | Occupied_non_tool_block
         | Invalid_tool_block _
         | Invalid_media_block
         | Active_media _ -> None)
      state.blocks_by_index
;;

let remember_tool_quarantines state ~kind tools =
  let tool_quarantines =
    List.fold_left
      (fun quarantines (tool : tool_ref) ->
         if
           List.exists
             (fun (quarantine : tool_quarantine) ->
                same_occurrence quarantine.occurrence tool.occurrence)
             quarantines
         then quarantines
         else { occurrence = tool.occurrence; kind } :: quarantines)
      state.tool_quarantines tools
  in
  { state with tool_quarantines }
;;

let finalized_tool_for_occurrence state
    (occurrence : Keeper_chat_events.tool_stream_occurrence) =
  List.find_opt
    (fun (finalized : tool_ref) ->
       same_occurrence finalized.occurrence occurrence)
    state.finalized_tools

let remember_finalized_tool state (tool : tool_ref) =
  if
    List.exists
      (fun (finalized : tool_ref) ->
         same_occurrence finalized.occurrence tool.occurrence)
      state.finalized_tools
  then state
  else { state with finalized_tools = tool :: state.finalized_tools }

let stream_start_is_tool ~index ~content_type ~tool_id ~tool_name =
  Agent_core.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal
    (Agent_core.Types.ContentBlockStart
       { index; content_type; tool_id; tool_name })

let stream_start_is_media content_type =
  String.equal content_type "image"
  || String.equal content_type "audio"
  || String.equal content_type "document"
;;

let has_any_tool_identity ~tool_id ~tool_name =
  match tool_id, tool_name with
  | None, None -> false
  | _ -> true
;;

let protocol_error ?quarantined_occurrence ?index ?tool_call_id ?event_type ?reason
    ?raw_bytes kind =
  Keeper_chat_events.Agent_core_stream_protocol_error
    { kind
    ; quarantined_occurrence
    ; index
    ; tool_call_id
    ; event_type
    ; reason
    ; raw_bytes
    }

let message_start_equal
    (left_id, left_model, left_usage)
    (right_id, right_model, right_usage) =
  String.equal left_id right_id
  && String.equal left_model right_model
  && Option.equal ( = ) left_usage right_usage
;;

let tools_in_current_scope state =
  let current_scope = state.current_stream_scope in
  let active =
    state.blocks_by_index
    |> List.filter_map (fun (_, block) ->
      match block with
      | Active_tool tool -> Some tool
      | Occupied_non_tool_block
      | Invalid_tool_block _
      | Active_media _
      | Invalid_media_block -> None)
  in
  let finalized =
    state.finalized_tools
    |> List.filter (fun (tool : tool_ref) ->
      Option.equal Int.equal current_scope (Some tool.occurrence.stream_scope))
  in
  (active @ finalized)
  |> List.filter (fun (tool : tool_ref) ->
    not (occurrence_is_quarantined state tool.occurrence))
  |> List.sort_uniq (fun (left : tool_ref) (right : tool_ref) ->
    let scope =
      Int.compare left.occurrence.stream_scope right.occurrence.stream_scope
    in
    if scope <> 0
    then scope
    else Int.compare left.occurrence.block_index right.occurrence.block_index)
;;

let poison_scope state ~kind ~reason =
  let tools = tools_in_current_scope state in
  let chat_events =
    match tools with
    | [] -> [ protocol_error ~reason kind ]
    | tools ->
      List.map
        (fun (tool : tool_ref) ->
           protocol_error ~quarantined_occurrence:tool.occurrence
             ~index:tool.occurrence.block_index
             ?tool_call_id:tool.tool_call_id ~reason kind)
        tools
  in
  let blocks_by_index =
    List.map
      (fun (index, block) ->
         match block with
         | Active_tool tool ->
           ( index
           , Invalid_tool_block
               { failed_tool_call_id = tool.tool_call_id
               ; quarantined_occurrence = Some tool.occurrence
               ; quarantine_kind = Some kind
               } )
         | Occupied_non_tool_block
         | Invalid_tool_block _
         | Active_media _
         | Invalid_media_block -> index, block)
      state.blocks_by_index
  in
  let state = remember_tool_quarantines state ~kind tools in
  { bridge_state =
      { state with
        blocks_by_index
      ; scope_failure = Some (kind, reason)
      ; message_open = false
      }
  ; chat_events
  }
;;

let poison_scope_with state ~kind ~reason ~diagnostic extra_events =
  let had_tools = tools_in_current_scope state <> [] in
  let poisoned = poison_scope state ~kind ~reason in
  { poisoned with
    chat_events =
      (if had_tools then poisoned.chat_events else [ diagnostic ]) @ extra_events
  }
;;

let start_runtime_attempt ~previous_scope state =
  let reason = "tool occurrence superseded by a new runtime attempt" in
  let terminalized =
    match previous_scope with
    | Keeper_chat_events.Preserve_previous_scope ->
      { bridge_state = state; chat_events = [] }
    | Keeper_chat_events.Abandon_previous_scope ->
      if tools_in_current_scope state = []
      then { bridge_state = state; chat_events = [] }
      else
        poison_scope state ~kind:Keeper_chat_events.Tool_attempt_superseded
          ~reason
  in
  { bridge_state = reset_runtime_attempt_state terminalized.bridge_state
  ; chat_events =
      terminalized.chat_events
      @ [ Keeper_chat_events.Agent_core_runtime_attempt_started ]
  }
;;

let fail_stream state ~reason =
  match state.scope_failure with
  | Some _ -> { bridge_state = state; chat_events = [] }
  | None ->
    poison_scope state ~kind:Keeper_chat_events.Sse_stream_incomplete ~reason
;;

let reject_non_input_tool_delta ~stream_scope ~index ~delta_kind bridge_state =
  let reject (tool : tool_ref) =
    let reason =
      Printf.sprintf "non-input %s delta arrived for a tool-use block" delta_kind
    in
    Some
      { bridge_state =
          invalidate_block ~quarantined_occurrence:tool.occurrence
            ~quarantine_kind:Keeper_chat_events.Tool_delta_invalid_kind
            bridge_state index ~failed_tool_call_id:tool.tool_call_id
      ; chat_events =
          [ protocol_error ~quarantined_occurrence:tool.occurrence
              ~index ?tool_call_id:tool.tool_call_id ~reason
              Keeper_chat_events.Tool_delta_invalid_kind
          ]
      }
  in
  match stream_block_for_index bridge_state index with
  | Some (Active_tool tool) -> reject tool
  | Some
      (Invalid_tool_block { failed_tool_call_id; quarantined_occurrence; _ }) ->
    let reason =
      Printf.sprintf "non-input %s delta arrived for an invalid tool-use block"
        delta_kind
    in
    Some
      { bridge_state
      ; chat_events =
          [ protocol_error ?quarantined_occurrence ~index
              ?tool_call_id:failed_tool_call_id ~reason
              Keeper_chat_events.Tool_delta_invalid_kind
          ]
      }
  | Some (Occupied_non_tool_block | Active_media _ | Invalid_media_block) -> None
  | None ->
    let occurrence : Keeper_chat_events.tool_stream_occurrence =
      { stream_scope
      ; provider_message_id = bridge_state.current_provider_message_id
      ; block_index = index
      }
    in
    (match finalized_tool_for_occurrence bridge_state occurrence with
     | Some tool -> reject tool
     | None -> None)

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

let add_media_chunk ~max_bytes ~media_type ~source_type ~chunks ~encoded_bytes data =
  let encoded_bytes = encoded_bytes + String.length data in
  if encoded_bytes > max_bytes
  then Error (encoded_bytes, max_bytes)
  else Ok (Active_media { media_type; source_type; chunks = data :: chunks; encoded_bytes })

let media_payload_too_large_event ~index ~size_bytes ~max_bytes =
  protocol_error ~index ~raw_bytes:size_bytes
    ~reason:(media_payload_too_large_reason ~size_bytes ~max_bytes)
    Keeper_chat_events.Media_payload_too_large

let finalize_media_block ~max_wire_bytes ~redact_text ~base_dir ~index ~media_type
    ~source_type ~chunks ~encoded_bytes =
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
      [ Keeper_chat_events.Agent_core_media_delta
          { index; media_type; source_type; media_ref }
      ]
  | Error err ->
      [ protocol_error ~index ~raw_bytes:(String.length data)
          ~reason:(redact_text (media_persist_protocol_reason err))
          (media_persist_error_kind err)
      ]

let close_open_content_blocks ~redact_text ~base_dir state =
  let ordered =
    List.sort
      (fun (left, _) (right, _) -> Int.compare left right)
      state.blocks_by_index
  in
  let state = { state with blocks_by_index = [] } in
  List.fold_left
    (fun ({ bridge_state; chat_events } : translated_event) (index, block) ->
       match block with
       | Active_tool tool ->
         { bridge_state = remember_finalized_tool bridge_state tool
         ; chat_events =
             chat_events
             @ [ Keeper_chat_events.Tool_call_end
                   { occurrence = tool.occurrence
                   ; tool_call_id = tool.tool_call_id
                   }
               ]
         }
       | Active_media { media_type; source_type; chunks; encoded_bytes } ->
         { bridge_state =
             replace_block bridge_state index Occupied_non_tool_block
         ; chat_events =
             chat_events
             @ finalize_media_block
                 ~max_wire_bytes:bridge_state.max_wire_bytes
                 ~redact_text ~base_dir ~index ~media_type ~source_type
                 ~chunks ~encoded_bytes
         }
       | Occupied_non_tool_block
       | Invalid_tool_block _
       | Invalid_media_block ->
         { bridge_state = replace_block bridge_state index block; chat_events })
    { bridge_state = state; chat_events = [] }
    ordered
;;

let content_block_start_event ~index ~content_type ~tool_id ~tool_name =
  Keeper_chat_events.Agent_core_content_block_start
    { index
    ; content_type
    ; tool_call_id = tool_id
    ; tool_call_name = tool_name
    }

let content_block_stop_event ~index =
  Keeper_chat_events.Agent_core_content_block_stop { index }

let tool_occurrence bridge_state ~stream_scope ~block_index =
  { Keeper_chat_events.stream_scope
  ; provider_message_id = bridge_state.current_provider_message_id
  ; block_index
  }

let tool_args_event ~redact_text ~stream_scope ~snapshot bridge_state index args =
  let open Keeper_chat_events in
  match stream_block_for_index bridge_state index with
  | Some (Active_tool tool) ->
      let bridge_state =
        replace_block bridge_state index
          (Active_tool (append_tool_args ~snapshot tool args))
      in
      let args = redact_text args in
      let chat_event =
        if snapshot then
          Tool_call_args_snapshot
            { occurrence = tool.occurrence
            ; tool_call_id = tool.tool_call_id
            ; snapshot = args
            }
        else
          Tool_call_args
            { occurrence = tool.occurrence
            ; tool_call_id = tool.tool_call_id
            ; delta = args
            }
      in
      { bridge_state; chat_events = [ chat_event ] }
  | Some
      (Invalid_tool_block { failed_tool_call_id; quarantined_occurrence; _ }) ->
      { bridge_state;
        chat_events =
          [ protocol_error ?quarantined_occurrence
              ?tool_call_id:failed_tool_call_id ~index
              ~reason:"tool argument event arrived after invalid tool block start"
              Tool_args_without_start ]
      }
  | Some Occupied_non_tool_block ->
      { bridge_state
      ; chat_events =
          [ protocol_error ~index
              ~reason:"tool argument event arrived for an occupied non-tool block"
              Tool_args_without_start
          ]
      }
  | Some Invalid_media_block ->
      { bridge_state;
        chat_events =
          [ protocol_error ~index
              ~reason:"tool argument event arrived after invalid media block"
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
      let occurrence : Keeper_chat_events.tool_stream_occurrence =
        { stream_scope
        ; provider_message_id = bridge_state.current_provider_message_id
        ; block_index = index
        }
      in
      (match finalized_tool_for_occurrence bridge_state occurrence with
       | Some tool ->
         { bridge_state =
             invalidate_block ~quarantined_occurrence:tool.occurrence
               ~quarantine_kind:Keeper_chat_events.Tool_args_without_start
               bridge_state index ~failed_tool_call_id:tool.tool_call_id
         ; chat_events =
             [ protocol_error ~quarantined_occurrence:tool.occurrence
                 ~index ?tool_call_id:tool.tool_call_id
                 ~reason:"tool argument event arrived after tool block stop"
                 Tool_args_without_start
             ]
         }
       | None ->
         { bridge_state = occupy_non_tool_index bridge_state index
         ; chat_events =
             [ protocol_error ~index
                 ~reason:"tool argument event arrived before tool start"
                 Tool_args_without_start
             ]
         })

let content_event_allowed state (evt : Agent_core.Types.sse_event) =
  match evt, state.stream_phase with
  | (Agent_core.Types.ContentBlockStart _ | Agent_core.Types.ContentBlockDelta _),
    Accepting_content -> true
  | Agent_core.Types.ContentBlockStop _,
    (Accepting_content | Stop_reason_seen _) -> true
  | (Agent_core.Types.ContentBlockStart _ | Agent_core.Types.ContentBlockDelta _
    | Agent_core.Types.ContentBlockStop _),
    (Stop_reason_seen _ | Message_stopped) -> false
  | _ -> true
;;

let reject_quarantined_content_event ~stream_scope state
    (evt : Agent_core.Types.sse_event) =
  let open Agent_core.Types in
  let index =
    match evt with
    | ContentBlockStart { index; _ }
    | ContentBlockDelta { index; _ }
    | ContentBlockStop { index } -> Some index
    | MessageStart _
    | MessageDelta _
    | MessageStop
    | Ping
    | SSEError _
    | NDJSONError _
    | SSEParseFailed _
    | NDJSONParseFailed _
    | SSEUnknownEventType _
    | SSEUnsupportedPart _
    | SSEUnsupportedResponse _
    | Connected
    | Timeout _
    | StreamIncomplete _ | StreamRepeating _ -> None
  in
  match index with
  | None -> None
  | Some index ->
    let occurrence = tool_occurrence state ~stream_scope ~block_index:index in
    (match first_quarantine_kind state occurrence with
     | Some _ -> Some { bridge_state = state; chat_events = [] }
     | None when occurrence_is_quarantined state occurrence ->
       (* Defensive compatibility for a state created before quarantine kinds
          became mandatory. The first exact error is still write-once. *)
       Some { bridge_state = state; chat_events = [] }
     | None -> None)
;;

let translate ~redact_text ~base_dir ~stream_scope bridge_state
    (evt : Agent_core.Types.sse_event) =
  let open Agent_core.Types in
  let open Keeper_chat_events in
  let bridge_state = enter_stream_scope bridge_state stream_scope in
  let quarantined_content_rejection =
    reject_quarantined_content_event ~stream_scope bridge_state evt
  in
  match bridge_state.scope_failure, quarantined_content_rejection with
  | Some _, _ -> { bridge_state; chat_events = [] }
  | None, Some rejected when tools_in_current_scope bridge_state = [] -> rejected
  | None, _ when not (content_event_allowed bridge_state evt) ->
    poison_scope bridge_state ~kind:Keeper_chat_events.Stream_event_after_terminal
      ~reason:"content event arrived after the provider content became terminal"
  | None, Some rejected -> rejected
  | None, None ->
  match evt with
  | Connected ->
      { bridge_state; chat_events = [ Agent_core_stream_connected ] }
  | MessageStart { id; model; usage } ->
      let incoming_start = id, model, usage in
      let provider_message_id =
        if String.trim id = "" then None else Some id
      in
      let message_start =
        Agent_core_stream_message_start
          { provider_message_id = id; model; usage }
      in
      if bridge_state.stream_phase <> Accepting_content
      then
        poison_scope bridge_state ~kind:Stream_event_after_terminal
          ~reason:"MessageStart arrived after the provider message became terminal"
      else if Option.is_none bridge_state.current_message_start
      then
        { bridge_state =
            { bridge_state with
              current_message_has_text = false
            ; message_open = true
            ; current_provider_message_id = provider_message_id
            ; current_message_start = Some incoming_start
            }
        ; chat_events = [ message_start ]
        }
      else if
        Option.equal message_start_equal
          (Some incoming_start) bridge_state.current_message_start
      then { bridge_state; chat_events = [ message_start ] }
      else
        let poisoned =
          poison_scope bridge_state ~kind:Tool_message_start_conflict
            ~reason:"conflicting MessageStart invalidated the provider stream scope"
        in
        { poisoned with chat_events = message_start :: poisoned.chat_events }
  | MessageDelta { stop_reason; usage } ->
      let message_delta = Agent_core_stream_message_delta { stop_reason; usage } in
      (match bridge_state.stream_phase, stop_reason with
       | Accepting_content, None ->
         { bridge_state; chat_events = [ message_delta ] }
       | Accepting_content, Some stop_reason ->
         let closed = close_open_content_blocks ~redact_text ~base_dir bridge_state in
         { bridge_state =
             { closed.bridge_state with
               stream_phase = Stop_reason_seen stop_reason
             }
         ; chat_events = message_delta :: closed.chat_events
         }
       | Stop_reason_seen _, None ->
         { bridge_state; chat_events = [ message_delta ] }
       | Stop_reason_seen recorded, Some replay when recorded = replay ->
         { bridge_state; chat_events = [ message_delta ] }
       | Stop_reason_seen _, Some _
       | Message_stopped, None
       | Message_stopped, Some _ ->
         poison_scope bridge_state ~kind:Stream_event_after_terminal
           ~reason:"MessageDelta conflicted with the frozen terminal state")
  | MessageStop ->
      (match bridge_state.stream_phase with
       | Message_stopped ->
         { bridge_state; chat_events = [ Agent_core_stream_message_stop ] }
       | Accepting_content | Stop_reason_seen _ ->
         let closed = close_open_content_blocks ~redact_text ~base_dir bridge_state in
         { bridge_state =
             { closed.bridge_state with
               stream_phase = Message_stopped
             ; current_message_has_text = false
             ; last_completed_message_has_text =
                 bridge_state.current_message_has_text
             ; message_open = false
             }
         ; chat_events = closed.chat_events @ [ Agent_core_stream_message_stop ]
         })
  | Ping ->
      { bridge_state; chat_events = [ Agent_core_stream_ping ] }
  | Timeout reason ->
      { bridge_state;
        chat_events =
          [ Event_error { message = redact_text ("Timeout: " ^ reason) } ]
      }
  | ContentBlockDelta { index; delta = TextSnapshot _ } ->
      poison_scope bridge_state ~kind:Sse_parse_failed
        ~reason:
          (Printf.sprintf
             "unresolved text snapshot crossed the canonical stream boundary at index %d"
             index)
  | ContentBlockDelta { index; delta = TextDelta text } -> (
      match
        reject_non_input_tool_delta ~stream_scope ~index ~delta_kind:"text"
          bridge_state
      with
      | Some rejected -> rejected
      | None ->
        let bridge_state = occupy_non_tool_index bridge_state index in
        { bridge_state =
            { bridge_state with
              current_message_has_text =
                bridge_state.current_message_has_text || not (String.equal text "")
            }
        ; chat_events = [ Text_delta (redact_text text) ]
        })
  | ContentBlockDelta { index; delta = ThinkingDelta text } ->
      (match
         reject_non_input_tool_delta ~stream_scope ~index ~delta_kind:"thinking"
           bridge_state
       with
       | Some rejected -> rejected
       | None ->
         { bridge_state = occupy_non_tool_index bridge_state index
         ; chat_events =
             [ Agent_core_thinking_delta { index; delta = redact_text text } ]
         })
  | ContentBlockDelta
      { index; delta = ReasoningDetailsDelta { reasoning_content; details } } ->
      (* MiniMax split-reasoning stream (#2347): project the reasoning payload
         through the thinking-delta lane so keepers surface it like other
         provider reasoning. AGENT_CORE owns the typed text projection. *)
      (match
         reject_non_input_tool_delta ~stream_scope ~index
           ~delta_kind:"reasoning-details" bridge_state
       with
       | Some rejected -> rejected
       | None ->
         let bridge_state = occupy_non_tool_index bridge_state index in
         let text =
           Agent_core.Types.reasoning_details_text ~reasoning_content ~details
         in
         { bridge_state
         ; chat_events =
             [ Agent_core_thinking_delta { index; delta = redact_text text } ]
         })
  | ContentBlockDelta { index; delta = ThinkingSignatureDelta signature } ->
      (match
         reject_non_input_tool_delta ~stream_scope ~index
           ~delta_kind:"thinking-signature" bridge_state
       with
       | Some rejected -> rejected
       | None ->
         { bridge_state = occupy_non_tool_index bridge_state index
         ; chat_events =
             [ Agent_core_thinking_signature_delta
                 { index; signature_bytes = String.length signature }
             ]
         })
  | ContentBlockDelta
      { index; delta = MediaDelta { media_type; source_type; data } } ->
      (* RFC-0301: accumulate the media payload across chunks in the block state;
         the persisted URL is emitted once at the block stop (or at message end if
         the stream never closes the block), not a per-chunk count. *)
      (match
         reject_non_input_tool_delta ~stream_scope ~index ~delta_kind:"media"
           bridge_state
       with
       | Some rejected -> rejected
       | None ->
       match stream_block_for_index bridge_state index with
       | Some (Active_media m)
         when String.equal m.media_type media_type && m.source_type = source_type
         ->
           (match
              add_media_chunk ~max_bytes:bridge_state.max_wire_bytes
                ~media_type ~source_type ~chunks:m.chunks
                ~encoded_bytes:m.encoded_bytes data
            with
            | Ok block ->
                { bridge_state = replace_block bridge_state index block; chat_events = [] }
            | Error (size_bytes, max_bytes) ->
                { bridge_state = invalidate_media_block bridge_state index;
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
       | Some Occupied_non_tool_block ->
         { bridge_state
         ; chat_events =
             [ protocol_error ~index
                 ~reason:"media delta arrived for an occupied non-tool block"
                 Media_delta_invalid_block
             ]
         }
       | Some (Active_tool tool) ->
           { bridge_state;
             chat_events =
               [ protocol_error ~index ?tool_call_id:tool.tool_call_id
                   ~reason:"media delta arrived for an active tool block"
                   Media_delta_invalid_block ]
           }
      | Some
          (Invalid_tool_block { failed_tool_call_id; quarantined_occurrence; _ }) ->
          { bridge_state;
            chat_events =
              [ protocol_error ?quarantined_occurrence
                  ?tool_call_id:failed_tool_call_id ~index
                  ~reason:"media delta arrived for an invalid tool block"
                  Media_delta_invalid_block ]
          }
      | Some Invalid_media_block -> { bridge_state; chat_events = [] }
      | None ->
          (match
             add_media_chunk ~max_bytes:bridge_state.max_wire_bytes
                ~media_type ~source_type ~chunks:[]
                ~encoded_bytes:0 data
            with
            | Ok block ->
                { bridge_state = replace_block bridge_state index block; chat_events = [] }
            | Error (size_bytes, max_bytes) ->
                { bridge_state = invalidate_media_block bridge_state index;
                  chat_events =
                    [ media_payload_too_large_event ~index ~size_bytes ~max_bytes ]
                }))
  | ContentBlockStart { index; content_type; tool_id; tool_name }
    when stream_start_is_tool ~index ~content_type ~tool_id ~tool_name -> (
      let tool_call_id =
        Option.bind tool_id (fun id ->
          if String.trim id = "" then None else Some id)
      in
      match tool_call_id, tool_name with
      | Some _, Some tname when String.trim tname <> "" ->
      let occurrence = tool_occurrence bridge_state ~stream_scope ~block_index:index in
      let tool =
        { occurrence
        ; tool_call_id
        ; tool_call_name = tname
        ; args_fragments = []
        }
      in
      let existing_block = stream_block_for_index bridge_state index in
      let block_start =
        content_block_start_event ~index ~content_type ~tool_id
          ~tool_name:(Some tname)
      in
      (match existing_block with
       | Some (Active_tool existing)
         when tool_start_is_replay existing tool && existing.args_fragments = [] ->
           { bridge_state; chat_events = [ block_start ] }
       | Some (Active_tool existing) ->
           { bridge_state =
               invalidate_block ~quarantined_occurrence:existing.occurrence
                 ~quarantine_kind:Keeper_chat_events.Tool_start_duplicate_index
                 bridge_state index
                 ~failed_tool_call_id:existing.tool_call_id;
             chat_events =
               [ block_start;
                 protocol_error ~quarantined_occurrence:existing.occurrence
                   ~index ?tool_call_id:existing.tool_call_id
                   ~reason:
                     (Printf.sprintf
                        "tool-use block index already active: existing tool %s/%s, incoming tool %s/%s"
                        (diagnostic_provider_id existing.tool_call_id)
                        existing.tool_call_name
                        (diagnostic_provider_id tool_call_id)
                        tname)
                   Tool_start_duplicate_index ]
           }
       | Some Occupied_non_tool_block ->
         { bridge_state =
             invalidate_block
               ~quarantine_kind:Keeper_chat_events.Tool_start_duplicate_index
               bridge_state index
               ~failed_tool_call_id:tool_call_id
         ; chat_events =
             [ block_start
             ; protocol_error ~index ?tool_call_id
                 ~reason:"tool-use block start arrived for an occupied index"
                 Tool_start_duplicate_index
             ]
         }
       | Some
           (Invalid_tool_block { failed_tool_call_id; quarantined_occurrence; _ }) ->
           { bridge_state;
             chat_events =
               [ block_start;
                 protocol_error ?quarantined_occurrence
                   ?tool_call_id:failed_tool_call_id ~index
                   ~reason:"tool-use block index already invalid"
                   Tool_start_duplicate_index ]
           }
       | Some Invalid_media_block ->
           { bridge_state;
             chat_events =
               [ block_start;
                 protocol_error ~index
                   ~reason:"tool-use block start arrived for an invalid media block index"
                   Tool_start_duplicate_index ]
           }
       | Some (Active_media _) ->
           { bridge_state =
               invalidate_block
                 ~quarantine_kind:Keeper_chat_events.Tool_start_duplicate_index
                 bridge_state index ~failed_tool_call_id:None;
             chat_events =
               [ block_start;
                 protocol_error ~index
                   ~reason:
                     "tool-use block start arrived for an active media block index"
                   Tool_start_duplicate_index ]
           }
       | None ->
           (match finalized_tool_for_occurrence bridge_state occurrence with
            | Some finalized ->
              { bridge_state =
                  invalidate_block
                    ~quarantined_occurrence:finalized.occurrence
                    ~quarantine_kind:Keeper_chat_events.Tool_start_duplicate_index
                    bridge_state index
                    ~failed_tool_call_id:finalized.tool_call_id
              ; chat_events =
                  [ block_start
                  ; protocol_error
                      ~quarantined_occurrence:finalized.occurrence
                      ~index ?tool_call_id:finalized.tool_call_id
                      ~reason:"tool-use block start arrived after block stop"
                      Tool_start_duplicate_index
                  ]
              }
            | None ->
              { bridge_state = replace_block bridge_state index (Active_tool tool)
              ; chat_events =
                  [ block_start
                  ; Tool_call_start
                      { occurrence; tool_call_id; tool_call_name = tname }
                  ]
              }))
      | None, _ | _, None | Some _, Some _ ->
          let block_start =
            content_block_start_event ~index ~content_type ~tool_id ~tool_name
          in
          let invalidate ?quarantined_occurrence ?tool_call_id () =
            { bridge_state =
                invalidate_block ?quarantined_occurrence
                  ~quarantine_kind:Keeper_chat_events.Tool_start_missing_identity
                  bridge_state index
                  ~failed_tool_call_id:tool_call_id
            ; chat_events =
                [ block_start
                ; protocol_error ?quarantined_occurrence ~index ?tool_call_id
                    ~reason:"tool-use block start missed tool id or name"
                    Tool_start_missing_identity
                ]
            }
          in
          (match stream_block_for_index bridge_state index with
           | Some (Active_tool existing) ->
             invalidate ~quarantined_occurrence:existing.occurrence
               ?tool_call_id:existing.tool_call_id ()
           | Some
               (Invalid_tool_block
                 { failed_tool_call_id; quarantined_occurrence; _ }) ->
             invalidate ?quarantined_occurrence
               ?tool_call_id:failed_tool_call_id ()
           | Some (Occupied_non_tool_block | Active_media _ | Invalid_media_block) ->
             invalidate ()
           | None ->
             let occurrence =
               tool_occurrence bridge_state ~stream_scope ~block_index:index
             in
             (match finalized_tool_for_occurrence bridge_state occurrence with
              | Some finalized ->
                invalidate ~quarantined_occurrence:finalized.occurrence
                  ?tool_call_id:finalized.tool_call_id ()
              | None -> invalidate ())))
  | ContentBlockStart { index; content_type; tool_id; tool_name } ->
      let block_start =
        content_block_start_event ~index ~content_type ~tool_id ~tool_name
      in
      let rejects_non_tool_identity =
        not (String.equal content_type Runtime_native_tools.stream_content_type)
        && has_any_tool_identity ~tool_id ~tool_name
      in
      let reject_non_tool_identity () =
        let incoming_tool_call_id =
          Option.bind tool_id (fun id ->
            let id = String.trim id in
            if String.equal id "" then None else Some id)
        in
        let occurrence =
          tool_occurrence bridge_state ~stream_scope ~block_index:index
        in
        let quarantined_occurrence, failed_tool_call_id =
          match stream_block_for_index bridge_state index with
          | Some (Active_tool existing) ->
            Some existing.occurrence, existing.tool_call_id
          | Some
              (Invalid_tool_block
                { failed_tool_call_id; quarantined_occurrence; _ }) ->
            quarantined_occurrence, failed_tool_call_id
          | Some (Occupied_non_tool_block | Active_media _ | Invalid_media_block) ->
            None, incoming_tool_call_id
          | None ->
            (match finalized_tool_for_occurrence bridge_state occurrence with
             | Some finalized ->
               Some finalized.occurrence, finalized.tool_call_id
             | None -> None, incoming_tool_call_id)
        in
        { bridge_state =
            invalidate_block ?quarantined_occurrence
              ~quarantine_kind:Keeper_chat_events.Tool_start_missing_identity
              bridge_state index ~failed_tool_call_id
        ; chat_events =
            [ block_start
            ; protocol_error ?quarantined_occurrence ~index
                ?tool_call_id:failed_tool_call_id
                ~reason:"non-tool content block carried tool id or name"
                Tool_start_missing_identity
            ]
        }
      in
      let conflict ?quarantined_occurrence ?tool_call_id reason =
        { bridge_state =
            invalidate_block ?quarantined_occurrence
              ~quarantine_kind:Keeper_chat_events.Tool_start_duplicate_index
              bridge_state index
              ~failed_tool_call_id:tool_call_id
        ; chat_events =
            [ block_start
            ; protocol_error ?quarantined_occurrence ~index ?tool_call_id
                ~reason Tool_start_duplicate_index
            ]
        }
      in
      if rejects_non_tool_identity
      then reject_non_tool_identity ()
      else (match stream_block_for_index bridge_state index with
       | Some (Active_tool existing) ->
         conflict ~quarantined_occurrence:existing.occurrence
           ?tool_call_id:existing.tool_call_id
           "non-tool content block header replaced an active tool occurrence"
       | Some
           (Invalid_tool_block { failed_tool_call_id; quarantined_occurrence; _ }) ->
         conflict ?quarantined_occurrence
           ?tool_call_id:failed_tool_call_id
           "non-tool content block header reused an invalid index"
       | Some (Occupied_non_tool_block | Active_media _ | Invalid_media_block) ->
         { bridge_state; chat_events = [ block_start ] }
       | None ->
         let occurrence =
           tool_occurrence bridge_state ~stream_scope ~block_index:index
         in
         (match finalized_tool_for_occurrence bridge_state occurrence with
          | Some finalized ->
            conflict ~quarantined_occurrence:finalized.occurrence
              ?tool_call_id:finalized.tool_call_id
              "non-tool content block header reused a closed tool occurrence"
          | None ->
            if stream_start_is_media content_type
            then { bridge_state; chat_events = [ block_start ] }
            else
              { bridge_state =
                  replace_block bridge_state index Occupied_non_tool_block
              ; chat_events = [ block_start ]
              }))
  | ContentBlockDelta { index; delta = InputJsonDelta args } ->
      tool_args_event ~redact_text ~stream_scope ~snapshot:false bridge_state index args
  | ContentBlockDelta { index; delta = InputJsonSnapshot args } ->
      tool_args_event ~redact_text ~stream_scope ~snapshot:true bridge_state index args
  | ContentBlockStop { index } -> (
      let block_stop = content_block_stop_event ~index in
      match stream_block_for_index bridge_state index with
      | Some (Active_tool tool) ->
          let bridge_state =
            remove_block bridge_state index
            |> fun state -> remember_finalized_tool state tool
          in
          { bridge_state;
            chat_events =
              [ block_stop
              ; Tool_call_end
                  { occurrence = tool.occurrence
                  ; tool_call_id = tool.tool_call_id
                  }
              ]
          }
      | Some Occupied_non_tool_block ->
        { bridge_state; chat_events = [ block_stop ] }
      | Some
          (Invalid_tool_block { failed_tool_call_id; quarantined_occurrence; _ }) ->
          { bridge_state
          ; chat_events =
              [ block_stop;
                protocol_error ?quarantined_occurrence
                  ?tool_call_id:failed_tool_call_id ~index
                  ~reason:"content block stop arrived for invalid tool block"
                  Tool_stop_without_start ]
          }
      | Some Invalid_media_block ->
          { bridge_state
          ; chat_events = [ block_stop ]
          }
      | Some (Active_media { media_type; source_type; chunks; encoded_bytes }) ->
          (* RFC-0301: the media block is complete — concat the accumulated chunks,
             persist to the media store, and emit the reader-facing URL (not a
             byte count). *)
          { bridge_state =
              replace_block bridge_state index Occupied_non_tool_block
          ; chat_events =
              block_stop
              :: finalize_media_block ~max_wire_bytes:bridge_state.max_wire_bytes
                   ~redact_text ~base_dir ~index ~media_type
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
      poison_scope_with bridge_state ~kind:Sse_error
        ~reason:(redact_text message)
        ~diagnostic:
          (protocol_error ?event_type:error_type ~reason:(redact_text message)
             Sse_error)
        [ Event_error
            { message = redact_text ("Provider stream error: " ^ reason) }
        ]
  | NDJSONError { message; error_type; raw } ->
      let reason =
        match error_type with
        | None -> message
        | Some error_type -> error_type ^ ": " ^ message
      in
      poison_scope_with bridge_state ~kind:Ndjson_error
        ~reason:(redact_text message)
        ~diagnostic:
          (protocol_error ?event_type:error_type
             ~reason:(redact_text message)
             ~raw_bytes:(String.length raw)
             Ndjson_error)
        [ Event_error
            { message =
                redact_text ("Provider NDJSON stream error: " ^ reason) }
        ]
  | SSEParseFailed { raw; reason } ->
      poison_scope_with bridge_state ~kind:Sse_parse_failed
        ~reason:(redact_text reason)
        ~diagnostic:
          (protocol_error ~reason:(redact_text reason)
             ~raw_bytes:(String.length raw) Sse_parse_failed)
        [ Event_error
            { message =
                redact_text ("Provider stream parse failed: " ^ reason) }
        ]
  | NDJSONParseFailed { raw; reason } ->
      poison_scope_with bridge_state ~kind:Ndjson_parse_failed
        ~reason:(redact_text reason)
        ~diagnostic:
          (protocol_error ~reason:(redact_text reason)
             ~raw_bytes:(String.length raw) Ndjson_parse_failed)
        [ Event_error
            { message =
                redact_text ("Provider NDJSON stream parse failed: " ^ reason) }
        ]
  | SSEUnknownEventType { event_type; raw } ->
      poison_scope_with bridge_state ~kind:Sse_unknown_event_type
        ~reason:("unknown provider event type: " ^ event_type)
        ~diagnostic:
          (protocol_error ~event_type ~raw_bytes:(String.length raw)
             Sse_unknown_event_type)
        []
  | SSEUnsupportedPart { provider_kind; part; raw } ->
      let provider = Agent_core.Llm_provider.Provider_kind.to_string provider_kind in
      let reason = redact_text (Printf.sprintf "%s.part.%s" provider part) in
      poison_scope_with bridge_state ~kind:Sse_unsupported_part ~reason
        ~diagnostic:
          (protocol_error ~event_type:part ~reason
             ~raw_bytes:(String.length raw) Sse_unsupported_part)
        [ Event_error
            { message = "Provider stream capability unsupported: " ^ reason }
        ]
  | SSEUnsupportedResponse { provider_kind; response; raw } ->
      let provider = Agent_core.Llm_provider.Provider_kind.to_string provider_kind in
      let reason = redact_text (Printf.sprintf "%s.response.%s" provider response) in
      poison_scope_with bridge_state ~kind:Sse_unsupported_response ~reason
        ~diagnostic:
          (protocol_error ~event_type:response ~reason
             ~raw_bytes:(String.length raw) Sse_unsupported_response)
        [ Event_error
            { message = "Provider stream capability unsupported: " ^ reason }
        ]
  | StreamIncomplete { reason } ->
      let redacted_reason = redact_text reason in
      let quarantined =
        poison_scope bridge_state ~kind:Sse_stream_incomplete
          ~reason:redacted_reason
      in
      { bridge_state =
          { quarantined.bridge_state with
            scope_failure = bridge_state.scope_failure
          ; message_open = bridge_state.message_open
          }
      ; chat_events =
          (if tools_in_current_scope bridge_state = []
           then []
           else quarantined.chat_events)
          @ [ protocol_error ~reason:redacted_reason Sse_stream_incomplete
            ; Event_error
                { message =
                    redact_text ("Provider stream incomplete: " ^ reason) }
            ]
      }
  | StreamRepeating { paragraph; occurrences; bytes_seen } ->
      (* Same shape as an incomplete stream: the scope is poisoned and the
         operator is told why. The reason names the repeat rather than a
         truncation, because the bytes arrived fine and the answer did not. *)
      let reason =
        redact_text
          (Printf.sprintf
             "generation repeated one paragraph %d times after %d bytes: %S"
             occurrences
             bytes_seen
             (if String.length paragraph <= 120
              then paragraph
              else String.sub paragraph 0 120))
      in
      let quarantined =
        poison_scope bridge_state ~kind:Sse_stream_repeating ~reason
      in
      { bridge_state =
          { quarantined.bridge_state with
            scope_failure = bridge_state.scope_failure
          ; message_open = bridge_state.message_open
          }
      ; chat_events =
          (if tools_in_current_scope bridge_state = []
           then []
           else quarantined.chat_events)
          @ [ protocol_error ~reason Sse_stream_repeating
            ; Event_error { message = reason }
            ]
      }
