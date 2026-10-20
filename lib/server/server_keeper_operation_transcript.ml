type settlement =
  | Runtime_deferred
  | Reply of string
  | Request_failed of string

let tool_delivery_key ~operation_id ~resumed_from =
  let ( let* ) = Result.bind in
  let delivery_key = Keeper_chat_delivery_identity.Operation operation_id in
  match resumed_from with
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
      Ok (Keeper_chat_delivery_identity.Operation_native {operation_id; continuation_id})

let committed_tool_events ~operation_id ~resumed_from tool_calls =
  Result.map
    (fun delivery_key ->
      List.map
        (fun ({ execution_id; ordinal } : Keeper_chat_store.tool_ownership) ->
          Keeper_chat_events.Tool_transcript_committed { delivery_key; execution_id; ordinal })
        (Keeper_chat_store.tool_ownerships tool_calls))
    (tool_delivery_key ~operation_id ~resumed_from)

let persist ~base_dir ~keeper_name ~operation_id ~resumed_from ~settlement
    ~tool_calls ?surface ?conversation_id ?blocks ?turn_ref ?stream_lifecycle () =
  let ( let* ) = Result.bind in
  let delivery_key = Keeper_chat_delivery_identity.Operation operation_id in
  let* tool_delivery_key = tool_delivery_key ~operation_id ~resumed_from in
  let tools_only () = match tool_calls with
    | [] -> Ok ()
    | _ -> Keeper_chat_store.append_tool_calls_once ~base_dir ~keeper_name
        ~delivery_key:tool_delivery_key ~tool_calls ?surface ?conversation_id ?turn_ref ()
        |> Result.map (fun _ -> ()) in
  let terminal append =
    let* terminal_tools = match resumed_from with
      | None -> Ok tool_calls
      | Some _ -> let* () = tools_only () in Ok [] in
    append terminal_tools |> Result.map (fun _ -> ()) in
  match settlement with
  | Runtime_deferred -> tools_only ()
  | Reply content ->
    terminal (fun tool_calls ->
      Keeper_chat_store.append_assistant_message_once ~base_dir ~keeper_name ~delivery_key
        ~content ?surface ?conversation_id ~tool_calls ?blocks ?turn_ref ?stream_lifecycle ())
  | Request_failed content ->
    terminal (fun tool_calls ->
      Keeper_chat_store.append_request_failure_once ~base_dir ~keeper_name ~delivery_key
        ~content ~route:(Lazy.from_val { Keeper_chat_store.Row_route.surface; conversation_id })
        ~tool_calls ?blocks ?turn_ref ?stream_lifecycle ())
