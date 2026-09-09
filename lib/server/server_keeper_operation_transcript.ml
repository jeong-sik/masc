type settlement =
  | Runtime_deferred
  | Terminal of { content : string; kind : Keeper_chat_store.Row_kind.t }

let persist ~base_dir ~keeper_name ~operation_id ~resumed_from ~settlement
    ~tool_calls ?surface ?conversation_id ?blocks ?turn_ref ?stream_lifecycle () =
  let ( let* ) = Result.bind in
  let delivery_key = Keeper_chat_delivery_identity.Operation operation_id in
  let tool_delivery_key = match resumed_from with
    | None -> delivery_key
    | Some checkpoint -> Keeper_chat_delivery_identity.Operation_checkpoint {operation_id; checkpoint} in
  let tools_only () = match tool_calls with
    | [] -> Ok ()
    | _ -> Keeper_chat_store.append_tool_calls_once ~base_dir ~keeper_name
        ~delivery_key:tool_delivery_key ~tool_calls ?surface ?conversation_id ?turn_ref ()
        |> Result.map (fun _ -> ()) in
  match settlement with
  | Runtime_deferred -> tools_only ()
  | Terminal {content; kind} ->
    let* terminal_tools = match resumed_from with
      | None -> Ok tool_calls
      | Some _ -> let* () = tools_only () in Ok [] in
    Keeper_chat_store.append_assistant_message_once ~base_dir ~keeper_name
      ~delivery_key ~content ~assistant_kind:kind ~tool_calls:terminal_tools
      ?surface ?conversation_id ?blocks ?turn_ref ?stream_lifecycle ()
    |> Result.map (fun _ -> ())
