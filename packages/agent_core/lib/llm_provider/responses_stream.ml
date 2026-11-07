(* See responses_stream.mli for module rationale. *)

open Types
open Openai_stream_state

let responses_member_string_opt key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_string_option
;;

let responses_member_int_default key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_int_option |> Option.value ~default:0
;;

let responses_usage_of_response response =
  let open Yojson.Safe.Util in
  match response |> member "usage" with
  | `Assoc _ as usage ->
    let input_tokens = responses_member_int_default "input_tokens" usage in
    let output_tokens = responses_member_int_default "output_tokens" usage in
    let cache_read_input_tokens =
      match usage |> member "input_tokens_details" with
      | `Assoc _ as details -> responses_member_int_default "cached_tokens" details
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> 0
    in
    Some
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens
      ; cost_usd = None
      }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_output_has_function_call response =
  let open Yojson.Safe.Util in
  match response |> member "output" with
  | `List items ->
    List.exists
      (fun item ->
         match responses_member_string_opt "type" item with
         | Some ("function_call" | "custom_tool_call") -> true
         | Some _ | None -> false)
      items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> false
;;

let responses_incomplete_reason_opt response =
  let open Yojson.Safe.Util in
  match response |> member "incomplete_details" with
  | `Assoc _ as details -> responses_member_string_opt "reason" details
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_incomplete_reason response =
  responses_incomplete_reason_opt response |> Option.value ~default:"incomplete"
;;

let responses_failed_message response =
  let open Yojson.Safe.Util in
  match response |> member "error" with
  | `Assoc _ as err -> responses_member_string_opt "message" err
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_stop_reason_of_response response =
  Responses_stop_reason.of_status
    ~status:(responses_member_string_opt "status" response)
    ~incomplete_reason:(responses_incomplete_reason_opt response)
    ~failed_message:(responses_failed_message response)
    ~has_tool_calls:(responses_output_has_function_call response)
  |> Option.map
       (Stop_reason_wire.with_refusal
          ~has_refusal:(Responses_stop_reason.has_refusal response))
;;

let responses_error_message json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc _ as err ->
    responses_member_string_opt "message" err |> Option.value ~default:"Responses error"
  | `String message -> message
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    responses_member_string_opt "message" json |> Option.value ~default:"Responses error"
;;

let responses_error_type json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc _ as err ->
    (match responses_member_string_opt "type" err with
     | Some _ as t -> t
     | None -> responses_member_string_opt "code" err)
  | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    responses_member_string_opt "code" json
;;

let responses_fresh_block state =
  let index = state.next_block_index in
  state.next_block_index <- index + 1;
  index
;;

let responses_ensure_thinking_block state emit ~output_index =
  (match state.thinking_state with
   | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
   | Thinking_started _ | Thinking_done -> ());
  match Hashtbl.find_opt state.responses_thinking_blocks output_index with
  | Some index -> index
  | None ->
    let index = responses_fresh_block state in
    Hashtbl.add state.responses_thinking_blocks output_index index;
    emit (ContentBlockStart
      {index;content_type="thinking";tool_id=None;tool_name=None});
    index
;;

let responses_ensure_text_block state emit ~output_index ~content_index =
  let key = output_index, content_index in
  match Hashtbl.find_opt state.responses_text_blocks key with
  | Some index -> index
  | None ->
    let index = responses_fresh_block state in
    Hashtbl.add state.responses_text_blocks key index;
    emit (ContentBlockStart {index;content_type="text";tool_id=None;tool_name=None});
    index
;;

let responses_tool_id_of_item item = responses_member_string_opt "call_id" item

let responses_ensure_tool_block state emit ~output_index ~tool_id ~tool_name =
  let resolution, start =
    resolve_tool_block
      state
      ~protocol:"openai_responses"
      ~wire_index:output_index
      ~provider_tool_id:tool_id
      ~tool_name
      ~index_policy:Next_available
      ~idless_semantics:Continue_by_wire_index
  in
  Option.iter emit start;
  match resolution with
  | Tool_block_resolved { block_index; _ } -> Some block_index
  | Tool_block_rejected error ->
    emit error;
    None
;;

let responses_assert_output_kind state emit output_index incoming =
    let effective = match Hashtbl.find_opt state.responses_output_kinds output_index, incoming with
      | None, (Response_replay.Message _ | Reasoning | Function_call as kind) -> Some kind
      | Some (Response_replay.Message previous), Response_replay.Message phase ->
        if phase=Response_replay.Absent then Some (Response_replay.Message previous)
        else if previous=Response_replay.Absent || previous=phase then Some incoming
        else None
      | Some Response_replay.Reasoning, Response_replay.Reasoning
      | Some Response_replay.Function_call, Response_replay.Function_call -> Some incoming
      | Some Response_replay.Reasoning, (Response_replay.Message _ | Function_call)
      | Some Response_replay.Function_call, (Response_replay.Message _ | Reasoning)
      | Some (Response_replay.Message _), (Reasoning | Function_call) -> None in
    match effective with
    | Some kind -> Hashtbl.replace state.responses_output_kinds output_index kind; Some kind
    | None -> emit(SSEParseFailed{raw="";reason="responses_replay:conflicting_item_kind_or_phase"});None
;;

let responses_accept_output_identity state emit output_index = function
  | None | Some "" -> true
  | Some id ->
    (match Hashtbl.find_opt state.responses_output_ids output_index with
     | None -> Hashtbl.add state.responses_output_ids output_index id;true
     | Some previous when String.equal previous id -> true
     | Some _ -> emit(SSEParseFailed{raw="";reason="responses_replay:conflicting_output_item_identity"});false)
;;

let responses_reasoning_update state emit ~output_index apply =
  let previous=Hashtbl.find_opt state.responses_reasoning output_index
    |> Option.value ~default:Responses_reasoning_stream.empty in
  match apply previous with
  | Error reason -> emit(SSEParseFailed{raw="";reason})
  | Ok(next,update) ->
    Hashtbl.replace state.responses_reasoning output_index next;
    (match update with
     | Responses_reasoning_stream.Unchanged -> ()
     | Append text ->
       let index=responses_ensure_thinking_block state emit ~output_index in
       emit(ContentBlockDelta{index;delta=ThinkingDelta text})
     | Replace text ->
       let index=responses_ensure_thinking_block state emit ~output_index in
       emit(ContentBlockDelta{index;delta=ThinkingSnapshot text})
     | Redact raw ->
       (match Hashtbl.find_opt state.responses_thinking_blocks output_index with
        | Some index -> emit(ContentBlockDelta{index;delta=RedactedThinkingSnapshot raw})
        | None ->
          let index=responses_fresh_block state in
          Hashtbl.add state.responses_thinking_blocks output_index index;
          emit(ContentBlockStart{index;content_type="redacted_thinking";tool_id=Some raw;tool_name=None})));
    Option.iter(fun index->Hashtbl.replace state.responses_output_groups output_index
      (Response_replay.Reasoning,[index]))
      (Hashtbl.find_opt state.responses_thinking_blocks output_index)
;;

let responses_capture_output_item ?(drop_function_call=false) state emit ~output_index item =
  let open Yojson.Safe.Util in
  let capture kind indices =
    Hashtbl.replace state.responses_output_groups output_index (kind, indices)
  in
  let assert_kind incoming = responses_assert_output_kind state emit output_index incoming in
  let identity_matches=responses_accept_output_identity state emit output_index
    (responses_member_string_opt "id" item) in
  if not identity_matches then ()
  else match responses_member_string_opt "type" item with
  | Some "message" ->
    let phase = match item with
      | `Assoc fields -> Response_replay.phase_of_fields fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "responses_replay:message_not_object" in
    (match phase with
     | Error reason -> emit (SSEParseFailed {raw="";reason})
     | Ok phase ->
       (match assert_kind (Response_replay.Message phase) with
        | None -> ()
        | Some kind ->
       let indices = match item |> member "content" with
         | `List parts -> List.mapi (fun content_index part -> content_index,part) parts
           |> List.filter_map (fun (content_index,part) ->
             match responses_member_string_opt "type" part,
                   responses_member_string_opt "text" part with
             | Some ("output_text" | "text"), Some text ->
               let index = responses_ensure_text_block state emit ~output_index ~content_index in
               emit (ContentBlockDelta {index;delta=TextSnapshot text});Some index
             | _ -> None)
         | `String text ->
           let index = responses_ensure_text_block state emit ~output_index ~content_index:0 in
           emit (ContentBlockDelta {index;delta=TextSnapshot text});[index]
         | `Null | `Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> [] in
       capture kind indices))
  | Some "reasoning" ->
    (match assert_kind Response_replay.Reasoning with
     | None -> ()
     | Some kind ->
    (match Responses_reasoning.decode item with
     | Error reason -> emit(SSEParseFailed{raw="";reason})
     | Ok incoming -> responses_reasoning_update state emit ~output_index
         (fun previous->Responses_reasoning_stream.item previous incoming));
    capture kind (Option.to_list(Hashtbl.find_opt state.responses_thinking_blocks output_index)))
  | Some "function_call" ->
    (match assert_kind Response_replay.Function_call with
     | None -> ()
     | Some kind ->
       if drop_function_call || responses_member_string_opt "status" item = Some "incomplete"
       then
         (* A cut-off call is never completed from its terminal snapshot. The
            accumulator's existing incomplete policy discards any held block. *)
         let indices = match Hashtbl.find_opt state.tool_block_indices output_index with
           | Some (Tool_index_single index) -> [index]
           | Some (Tool_index_ambiguous _) | None -> [] in
         capture kind indices
       else
         let item_for_decode, wire_tool_id =
           match responses_tool_id_of_item item with
           | Some id when not (Api_common.string_is_blank id) -> item, Some id
           | Some _ | None ->
             (match Hashtbl.find_opt state.tool_block_indices output_index with
              | Some (Tool_index_single block_index) ->
                (match Hashtbl.find_opt state.tool_block_identities block_index with
                 | Some { id; origin = Agent_core_allocated } ->
                   (match item with
                    | `Assoc fields ->
                      `Assoc (("call_id", `String id) :: List.remove_assoc "call_id" fields), None
                    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
                      item, None)
                 | Some { origin = Provider_supplied; _ } | None -> item, None)
              | Some (Tool_index_ambiguous _) | None -> item, None)
         in
         (match Responses_function_call.decode item_for_decode with
          | Error _ -> emit(SSEParseFailed{raw="";reason="responses_replay:malformed_function_call"})
          | Ok call ->
            let index = responses_ensure_tool_block state emit ~output_index
              ~tool_id:wire_tool_id ~tool_name:(Some call.name) in
            Option.iter (fun index ->
              emit(ContentBlockDelta{index;delta=InputJsonSnapshot call.arguments})) index;
            capture kind (Option.to_list index)))
  | Some "custom_tool_call" ->
    (* Preserve only an already assembled legacy stream block. This codec has
       no custom-input admission contract and cannot synthesize one here. *)
    (match Hashtbl.find_opt state.tool_block_indices output_index with
     | Some (Tool_index_single index) -> capture Response_replay.Function_call [index]
     | Some (Tool_index_ambiguous _) | None -> ())
  | Some _ | None -> ()
;;

let responses_capture_terminal_outputs state emit response =
  let open Yojson.Safe.Util in
  let drop_function_call = responses_member_string_opt "status" response = Some "incomplete" in
  (match response |> member "output" with
   | `List items ->
     Hashtbl.clear state.responses_output_groups;
     List.iteri (fun output_index item ->
       responses_capture_output_item ~drop_function_call state emit ~output_index item) items
   | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> ());
  let explicit_output=match response |> member "output" with `List _->true
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> false in
  if Hashtbl.length state.responses_output_groups > 0
     || (explicit_output && Hashtbl.length state.responses_thinking_blocks > 0) then
    emit (ResponsesOutputItems
      (Hashtbl.fold (fun index group acc -> (index,group)::acc) state.responses_output_groups []
       |> List.sort (fun (left,_) (right,_) -> Int.compare left right)
       |> List.map snd))
;;

let responses_sse_to_events (state : openai_stream_state) event_type data_str
  : sse_event list * Telemetry_event.t option
  =
  (* The Responses API delivers its terminal status via a [response.completed]
     event before this trailing sentinel, so [DONE] needs no synthesized
     terminal here -- the accumulator already has a stop_reason. *)
  if String.equal data_str Openai_wire.openai_done_sentinel
  then [], None
  else (
    (* Decode through the shared total boundary (#2620): a valid-JSON
       non-object frame raises Util.Type_error out of [member], which a
       Json_error-only guard would let escape the parser (agent-core boundary). *)
    let decode json =
      let open Yojson.Safe.Util in
      let evt_type =
        match event_type with
        | Some t when String.trim t <> "" -> t
        | Some _ | None -> Cli_common_json.member_str "type" json
      in
      let events = ref [] in
      let emit evt = events := evt :: !events in
      let emit_terminal response =
        emit
          (MessageDelta
             { stop_reason =
                 responses_stop_reason_of_response response
                 |> Option.map (Stop_reason_wire.with_refusal ~has_refusal:state.refusal_seen)
             ; usage =
                 Option.map
                   Types.delta_usage_of_api_usage
                   (responses_usage_of_response response)
             });
        emit MessageStop
      in
      (match evt_type with
       | "response.created" ->
         let response = json |> member "response" in
         emit
           (MessageStart
              { id = Cli_common_json.member_str "id" response
              ; model = Cli_common_json.member_str "model" response
              ; usage = responses_usage_of_response response
              })
       | "response.output_text.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let content_index = responses_member_int_default "content_index" json in
            let index = responses_ensure_text_block state emit ~output_index ~content_index in
            emit (ContentBlockDelta { index; delta = TextDelta delta })
          | Some _ | None -> ())
       | "response.refusal.delta" | "response.refusal.done" ->
         state.refusal_seen <- true
       | "response.output_text.done" ->
         (match responses_member_string_opt "text" json with
          | Some text ->
            let output_index=responses_member_int_default "output_index" json in
            let content_index=responses_member_int_default "content_index" json in
            let index=responses_ensure_text_block state emit ~output_index ~content_index in
            emit(ContentBlockDelta {index;delta=TextSnapshot text})
          | None -> ())
       | ("response.reasoning_summary_text.delta" | "response.reasoning_text.delta"
         | "response.reasoning_summary_text.done" | "response.reasoning_text.done") as event ->
         let channel,part_field,is_delta=match event with
           | "response.reasoning_text.delta" -> Responses_reasoning.Full,"content_index",true
           | "response.reasoning_text.done" -> Full,"content_index",false
           | "response.reasoning_summary_text.delta" -> Summary,"summary_index",true
           | _ -> Summary,"summary_index",false in
         let output_index=responses_member_int_default "output_index" json in
         if responses_accept_output_identity state emit output_index
             (responses_member_string_opt "item_id" json) then
           (match responses_assert_output_kind state emit output_index Response_replay.Reasoning with
            | None -> ()
            | Some _ ->
              match responses_member_string_opt (if is_delta then "delta" else "text") json with
              | None -> ()
              | Some text ->
                let part=responses_member_int_default part_field json in
                responses_reasoning_update state emit ~output_index (fun previous->
                  if is_delta then Responses_reasoning_stream.delta previous ~channel ~part text
                  else Responses_reasoning_stream.part_done previous ~channel ~part text))
       | "response.output_item.added" ->
         let output_index = responses_member_int_default "output_index" json in
         let item = json |> member "item" in
         (match responses_member_string_opt "type" item with
          | Some ("function_call" | "custom_tool_call") ->
            let (_ : int option) =
              responses_ensure_tool_block
                state
                emit
                ~output_index
                ~tool_id:(responses_tool_id_of_item item)
                ~tool_name:(responses_member_string_opt "name" item)
            in
            ()
          | Some _ | None -> ())
       | "response.output_item.done" ->
         let output_index=responses_member_int_default "output_index" json in
         responses_capture_output_item state emit ~output_index (json |> member "item")
       | "response.function_call_arguments.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let index =
              responses_ensure_tool_block
                state
                emit
                ~output_index
                  (* [call_id] is the function-call identity on every official
                   arguments event. [item_id] identifies only the output item
                   and is never substituted for it. *)
                ~tool_id:(responses_member_string_opt "call_id" json)
                ~tool_name:None
            in
            (match index with
             | Some index ->
               emit (ContentBlockDelta { index; delta = InputJsonDelta delta })
             | None -> ())
          | Some _ | None -> ())
       | "response.completed" | "response.incomplete" ->
         let response = json |> member "response" in
         responses_capture_terminal_outputs state emit response;
         (* A [response.incomplete] terminal means the turn was cut off, so any
            in-progress tool call is partial. Carry that to the accumulator
            (which drops partial tool blocks at finalize) for ANY incomplete
            reason — [stop_reason = MaxTokens] alone only covers
            max_output_tokens, not e.g. content_filter. (#2073 follow-up.) *)
         (match responses_member_string_opt "status" response with
          | Some "incomplete" ->
            emit (StreamIncomplete { reason = responses_incomplete_reason response })
          | Some _ | None -> ());
         emit_terminal response
       | "response.failed" | "error" ->
         emit
           (SSEError
              { message = responses_error_message json
              ; error_type = responses_error_type json
              ; provider_status = None
              ; report = Types.Provider_stated
              ; raw = data_str
              })
       | "response.in_progress"
       | "response.content_part.added"
       | "response.content_part.done"
       | "response.function_call_arguments.done"
       | "response.reasoning_summary_part.added"
       | "response.reasoning_summary_part.done"
       | "response.queued" -> ()
       | other -> emit (SSEUnknownEventType { event_type = other; raw = data_str }));
      List.rev !events, None
    in
    match Json_util.decode_json_with decode data_str with
    | Ok result -> result
    | Error reason -> [ SSEParseFailed { raw = data_str; reason } ], None)
;;
