module Operation = Keeper_chat_operation
module Payload = Keeper_chat_operation_payload

let decode (operation : Operation.t) =
  let open Result.Syntax in
  let* source = Payload.source_of_json operation.source in
  let* input = match operation.input with
    | None -> Error "queued operation has no input"
    | Some input -> Payload.input_of_json input in
  Ok (source, input)

let same_context (left : Payload.decoded_source) (right : Payload.decoded_source) =
  Keeper_continuation_channel.same_route left.continuation_channel right.continuation_channel
  && { left with external_message_id = None } = { right with external_message_id = None }

let merge_attachments existing incoming =
  List.fold_left (fun result (attachment : Keeper_chat_store.attachment) ->
    match result with
    | None -> None
    | Some existing ->
      match List.find_opt (fun (prior : Keeper_chat_store.attachment) ->
        String.equal prior.id attachment.id) existing with
      | None -> Some (existing @ [attachment])
      | Some prior when prior = attachment -> Some existing
      | Some _ -> None) (Some existing) incoming

let blocks (input : Payload.decoded_input) =
  match input.user_blocks with
  | [] -> [Keeper_multimodal_input.User_text input.message]
  | blocks ->
    if List.exists (function Keeper_multimodal_input.User_text _ -> true | User_image _ | User_document _ | User_audio _ -> false) blocks
    then blocks
    else Keeper_multimodal_input.User_text input.message :: blocks

let select head candidates =
  match decode head with
  | Error _ -> Ok None
  | Ok (source, first) ->
    let rec from_head = function
      | [] -> []
      | (operation : Operation.t) :: rest as candidates ->
        if Operation.Operation_id.equal operation.operation_id head.operation_id
        then candidates else from_head rest
    in
    let candidates = from_head candidates in
    let rec collect members inputs attachments = function
      | [] -> members, inputs, attachments
      | (operation : Operation.t) :: rest ->
        match decode operation with
        | Error _ -> members, inputs, attachments
        | Ok (candidate_source, input)
          when same_context source candidate_source
            && input.turn_instructions = first.turn_instructions
            && input.surface_context = first.surface_context ->
          (match merge_attachments attachments input.attachments with
           | None -> members, inputs, attachments
           | Some attachments ->
             collect (operation.operation_id :: members) (input :: inputs)
               attachments rest)
        | Ok _ -> members, inputs, attachments
    in
    let members, inputs, attachments = collect [] [] first.attachments candidates in
    match members with
    | [] | [_] -> Ok None
    | _ ->
      let inputs = List.rev inputs in
      let message = String.concat "\n\n" (List.map (fun (input : Payload.decoded_input) -> input.message) inputs) in
      let user_blocks = List.concat_map blocks inputs in
      let input = Payload.input_to_json ~message ~user_blocks ~attachments
        ~turn_instructions:first.turn_instructions ~surface_context:first.surface_context in
      Ok (Some { Keeper_chat_operation_store.members = List.rev members; input })

let event_for_member ~operation_id event =
  let id = Operation.Operation_id.to_string operation_id in
  match event with
  | Keeper_chat_events.Batch_bound binding -> Keeper_chat_events.Batch_bound {binding with operation_id}
  | Keeper_chat_events.Run_started { thread_id; _ } ->
    Keeper_chat_events.Run_started { thread_id; run_id = "keeper-operation-run-" ^ id }
  | Keeper_chat_events.Run_finished _ ->
    Keeper_chat_events.Run_finished { run_id = "keeper-operation-run-" ^ id }
  | Keeper_chat_events.Text_message_start { role; _ } ->
    Keeper_chat_events.Text_message_start { role; message_id = "keeper-operation-message-" ^ id }
  | Keeper_chat_events.Continuation_checkpoint checkpoint ->
    Keeper_chat_events.Continuation_checkpoint { checkpoint with request_id = Some id }
  | (Keeper_chat_events.Text_message_end | Keeper_chat_events.Agent_core_stream_connected | Keeper_chat_events.Agent_core_stream_ping | Keeper_chat_events.Text_delta _ | Keeper_chat_events.External_effect_completed _ | Keeper_chat_events.Event_error _ | Keeper_chat_events.Reply_details _ | Keeper_chat_events.Provider_retry_observed _ | Keeper_chat_events.Agent_core_runtime_attempt_started _ | Keeper_chat_events.Agent_core_stream_message_start _ | Keeper_chat_events.Agent_core_stream_message_delta _ | Keeper_chat_events.Agent_core_stream_message_stop _ | Keeper_chat_events.Agent_core_content_block_start _ | Keeper_chat_events.Agent_core_content_block_stop _ | Keeper_chat_events.Model_content_activity _ | (Keeper_chat_events.Agent_core_thinking_delta _ | Keeper_chat_events.Agent_core_thinking_snapshot _) | Keeper_chat_events.Agent_core_thinking_signature_delta _ | Keeper_chat_events.Agent_core_media_delta _ | Keeper_chat_events.Agent_core_stream_protocol_error _ | Keeper_chat_events.Tool_call_start _ | Keeper_chat_events.Tool_call_admitted _ | Keeper_chat_events.Tool_call_args _ | Keeper_chat_events.Tool_call_args_snapshot _ | Keeper_chat_events.Tool_call_end _ | Keeper_chat_events.Native_tool_start _ | Keeper_chat_events.Native_tool_end (_, _) | Keeper_chat_events.Native_tool_progress (_, _) | Keeper_chat_events.Tool_approval_requested _ | Keeper_chat_events.Tool_approval_settled _ | Keeper_chat_events.Tool_result_ready _ | Keeper_chat_events.Tool_transcript_committed _ | Keeper_chat_events.Link_block _ | Keeper_chat_events.Image_block _ | Keeper_chat_events.Status_block _ | Keeper_chat_events.Audio_block _ | Keeper_chat_events.Tool_context_block _) as event -> event
