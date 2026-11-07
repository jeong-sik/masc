(* The append-once reader answers "does this exact delivery already have a
   row?". A structurally decodable provenance whose execution identity is
   inconsistent is quarantined by its exact delivery key: a replay of that
   delivery fails closed, while unrelated future operations in the same JSONL
   remain writable. Fully undecodable provenance still fails the scan because
   no key can prove its blast radius. The rendering reader below can instead
   drop an invalid row because it never authorizes an append. *)
let execution_id_of_fields fields =
  match List.assoc_opt "execution_id" fields with
  | None -> Ok None
  | Some (`String raw) when String.trim raw <> "" ->
    Ok (Some (Ids.Execution_id.of_string raw))
  | Some (`String _) -> Error "row execution_id must not be blank"
  | Some _ -> Error "row execution_id must be a string"
;;

let validate_delivery_execution_identity ~execution_id
    (provenance : Keeper_chat_delivery_identity.delivery_provenance option) =
  match provenance with
  | None -> Ok ()
  | Some { transcript_slot; _ } -> (
      match transcript_slot, execution_id with
      | Keeper_chat_delivery_identity.Tool_call { execution_id = slot_id; _ },
        Some row_id
        when Ids.Execution_id.equal slot_id row_id ->
          Ok ()
      | Keeper_chat_delivery_identity.Tool_call _, Some _ ->
          Error "tool_call transcript slot conflicts with row execution_id"
      | Keeper_chat_delivery_identity.Tool_call _, None ->
          Error "tool_call transcript slot requires the same row execution_id"
      | Keeper_chat_delivery_identity.Tool_delivery _, None -> Ok ()
      | Keeper_chat_delivery_identity.Tool_delivery _, Some _ ->
          Error "tool_delivery transcript slot forbids row execution_id"
      | ( Keeper_chat_delivery_identity.Accepted_user
        | Keeper_chat_delivery_identity.Terminal_result
        | Keeper_chat_delivery_identity.Settled_failure
        | Keeper_chat_delivery_identity.Approval_request
        | Keeper_chat_delivery_identity.Approval_resolution
        | Keeper_chat_delivery_identity.Approval_replay
        | Keeper_chat_delivery_identity.Approval_replay_correction
        | Keeper_chat_delivery_identity.Approval_continuation ),
        None ->
          Ok ()
      | ( Keeper_chat_delivery_identity.Accepted_user
        | Keeper_chat_delivery_identity.Terminal_result
        | Keeper_chat_delivery_identity.Settled_failure
        | Keeper_chat_delivery_identity.Approval_request
        | Keeper_chat_delivery_identity.Approval_resolution
        | Keeper_chat_delivery_identity.Approval_replay
        | Keeper_chat_delivery_identity.Approval_replay_correction
        | Keeper_chat_delivery_identity.Approval_continuation ),
        Some _ ->
          Error "non-tool transcript slot forbids row execution_id")
;;

let validate_delivery_role ~role_label
    (provenance : Keeper_chat_delivery_identity.delivery_provenance) =
  match provenance.transcript_slot, role_label with
  | Keeper_chat_delivery_identity.Accepted_user, "user"
  | Keeper_chat_delivery_identity.Terminal_result, ("assistant" | "request_failure")
  | Keeper_chat_delivery_identity.Settled_failure, "request_failure"
  | ( Keeper_chat_delivery_identity.Approval_request
    | Keeper_chat_delivery_identity.Approval_resolution
    | Keeper_chat_delivery_identity.Approval_replay
    | Keeper_chat_delivery_identity.Approval_replay_correction
    | Keeper_chat_delivery_identity.Approval_continuation ),
    "system"
  | ( Keeper_chat_delivery_identity.Tool_call _
    | Keeper_chat_delivery_identity.Tool_delivery _ ),
    "tool" ->
    Ok ()
  | Keeper_chat_delivery_identity.Accepted_user, _ ->
    Error "accepted_user transcript slot requires a user row"
  | Keeper_chat_delivery_identity.Settled_failure, _ ->
    Error "settled_failure transcript slot requires a request_failure row"
  | Keeper_chat_delivery_identity.Terminal_result, _ ->
    Error "terminal_result transcript slot requires an assistant or request_failure row"
  | ( Keeper_chat_delivery_identity.Approval_request
    | Keeper_chat_delivery_identity.Approval_resolution
    | Keeper_chat_delivery_identity.Approval_replay
    | Keeper_chat_delivery_identity.Approval_replay_correction
    | Keeper_chat_delivery_identity.Approval_continuation ),
    _ ->
    Error "approval lifecycle transcript slot requires a system row"
  | ( Keeper_chat_delivery_identity.Tool_call _
    | Keeper_chat_delivery_identity.Tool_delivery _ ),
    _ ->
    Error "tool transcript slot requires a tool row"
;;
