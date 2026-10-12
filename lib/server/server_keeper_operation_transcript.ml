type settlement =
  | Runtime_deferred
  | Reply of string
  | Request_failed of string

let persist ~base_dir ~keeper_name ~operation_id ~resumed_from ~settlement
    ~tool_calls ?surface ?conversation_id ?blocks ?turn_ref ?stream_lifecycle () =
  let ( let* ) = Result.bind in
  let delivery_key = Keeper_chat_delivery_identity.Operation operation_id in
  let tool_delivery_key = match resumed_from with
    | None -> Ok delivery_key
    | Some (Keeper_semantic_execution.Agent_core checkpoint) ->
      Ok (Keeper_chat_delivery_identity.Operation_checkpoint {operation_id; checkpoint})
    | Some (Keeper_semantic_execution.Official_client checkpoint) ->
      (* The captured native turn distinguishes attempts; JSON framing preserves
         arbitrary provider identifiers without ambiguous string concatenation. *)
      let client = Keeper_semantic_execution.official_client_kind_to_string checkpoint.client_kind in
      let canonical = Yojson.Safe.to_string (`List (List.map (fun s -> `String s)
        [client; checkpoint.runtime_id; checkpoint.session_id; checkpoint.turn_id])) in
      let* continuation_id = Keeper_chat_delivery_identity.Request_id.of_string
        (Digestif.SHA256.(digest_string canonical |> to_hex)) in
      Ok (Keeper_chat_delivery_identity.Operation_native {operation_id; continuation_id}) in
  let* tool_delivery_key = tool_delivery_key in
  let tools_only () = match tool_calls with
    | [] -> Ok ()
    | _ -> Keeper_chat_store.append_tool_calls_once ~base_dir ~keeper_name
        ~delivery_key:tool_delivery_key ~tool_calls ?surface ?conversation_id ?turn_ref ()
        |> Result.map (fun _ -> ()) in
  let terminal append content =
    let* terminal_tools = match resumed_from with
      | None -> Ok tool_calls
      | Some _ -> let* () = tools_only () in Ok [] in
    append ~base_dir ~keeper_name ~delivery_key ~content
      ?surface ?conversation_id ?tool_calls:(Some terminal_tools) ?blocks ?turn_ref ?stream_lifecycle ()
    |> Result.map (fun _ -> ()) in
  match settlement with
  | Runtime_deferred -> tools_only ()
  | Reply content -> terminal Keeper_chat_store.append_assistant_message_once content
  | Request_failed content -> terminal Keeper_chat_store.append_request_failure_once content
