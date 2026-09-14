module Operation = Keeper_chat_operation
module Payload = Keeper_chat_operation_payload

let decode (operation : Operation.t) =
  let ( let* ) = Result.bind in
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
    let members, inputs, attachments = List.fold_left
      (fun (members, inputs, attachments) (operation : Operation.t) ->
        match decode operation with
        | Error _ -> members, inputs, attachments
        | Ok (candidate_source, input)
          when same_context source candidate_source
            && input.turn_instructions = first.turn_instructions
            && input.surface_context = first.surface_context ->
          (match merge_attachments attachments input.attachments with
           | None -> members, inputs, attachments
           | Some attachments -> operation.operation_id :: members, input :: inputs, attachments)
        | Ok _ -> members, inputs, attachments)
      ([], [], first.attachments) candidates in
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
  | event -> event
