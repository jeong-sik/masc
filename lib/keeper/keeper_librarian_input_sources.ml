type read_error =
  | Chat_store_unreadable of Keeper_chat_store.strict_decode_error
  | External_attention_unreadable of Keeper_external_attention.read_error
  | External_cursor_failed of string

let read_error_to_string = function
  | External_cursor_failed detail -> "external admission cursor: " ^ detail
  | Chat_store_unreadable error ->
    "keeper chat store is unreadable: "
    ^ Keeper_chat_store.strict_decode_error_to_string error
  | External_attention_unreadable error ->
    "external attention store is unreadable: "
    ^ Keeper_external_attention.read_error_to_string error
;;

open Result.Syntax
module Chat = Keeper_chat_store
module Attention = Keeper_external_attention

type counterpart_snapshot =
  { keeper_name : string
  ; after : float option
  ; before : float
  ; external_after : int option
  ; chat_rows : Chat.captured_row list
  ; external_log : Attention.item list
  }

let in_interval ~after ~before ts =
  ts <= before && match after with None -> true | Some lower -> ts > lower

let selected_chat ~after ~before (message : Chat.chat_message) =
  in_interval ~after ~before message.Chat.ts &&
  match message.Chat.role, message.Chat.speaker with
  | Chat.Role.User, Some _ -> true
  | Chat.Role.User, None
  | Chat.Role.Assistant, _ | Chat.Role.Request_failure, _
  | Chat.Role.System, _ | Chat.Role.Tool, _ -> false

let selected_external (snapshot : counterpart_snapshot) =
  match snapshot.external_after with
  | None ->
    List.filter (fun (item : Attention.item) ->
      in_interval ~after:snapshot.after ~before:snapshot.before item.received_at) snapshot.external_log
    |> List.stable_sort (fun (left : Attention.item) (right : Attention.item) ->
      Float.compare left.received_at right.received_at)
  | Some cursor ->
    List.drop cursor snapshot.external_log
    |> List.take_while (fun (item : Attention.item) -> item.received_at <= snapshot.before)

let external_through (snapshot : counterpart_snapshot) =
  match snapshot.external_after with
  | None -> List.length snapshot.external_log
  | Some cursor -> cursor + List.length (selected_external snapshot)

let counterpart_snapshot_matches_selection (snapshot : counterpart_snapshot) ~external_after ~after ~before =
  snapshot.external_after = Some external_after && snapshot.after = after && snapshot.before = before

let counterpart_observations (snapshot : counterpart_snapshot) =
  (* The complete original log supplies dedup identities, even outside this
     interval/frontier: a delivery and its chat projection can straddle it. *)
  let delivery_keys = List.filter_map (fun (item : Attention.item) ->
    Option.map (fun (message : Attention.external_message_ref) ->
      item.conversation.conversation_id, message.message_id) item.external_message) snapshot.external_log in
  let is_duplicate (message : Chat.chat_message) =
    match message.conversation_id, message.external_message_id with
    | Some conversation_id, Some message_id ->
      List.exists (fun (conversation, id) ->
        String.equal conversation_id conversation && String.equal message_id id) delivery_keys
    | None, _ | _, None -> false in
  let externals = selected_external snapshot |> List.map (fun (item : Attention.item) ->
    item.received_at, Keeper_counterpart_observation.of_external_attention item) in
  let chats = snapshot.chat_rows |> List.map Chat.captured_row_message
    |> List.filter (fun message -> not (is_duplicate message))
    |> List.filter_map (fun (message : Chat.chat_message) ->
      Option.map (fun observation -> message.ts, observation)
        (Keeper_counterpart_observation.of_chat_message message))
    |> List.stable_sort (fun (left, _) (right, _) -> Float.compare left right) in
  let rec interleave acc externals chats = match externals, chats with
    | [], rest | rest, [] -> List.rev_append acc rest
    | ((external_ts, _) as external_row) :: external_rest,
      ((chat_ts, _) as chat) :: chat_rest ->
      if Float.compare chat_ts external_ts < 0
      then interleave (chat :: acc) externals chat_rest
      else interleave (external_row :: acc) external_rest chats in
  interleave [] externals chats |> List.map snd

let capture_counterparts_read ?external_after ~base_dir ~keeper_name ~after ~before () =
  let* () = if Float.is_finite before && Option.fold ~none:true ~some:Float.is_finite after
    then Ok () else Error (External_cursor_failed "counterpart interval must be finite") in
  let* chat_rows = match after with
    | Some lower when Float.compare lower before >= 0 -> Ok []
    | Some _ | None -> Chat.load_captured_result ~select:(selected_chat ~after ~before) ~base_dir ~keeper_name
      |> Result.map_error (fun error -> Chat_store_unreadable error) in
  let* external_log = Attention.load_events_result ~base_path:base_dir ~keeper_name
    |> Result.map_error (fun error -> External_attention_unreadable error)
    |> Result.map (List.map (function Attention.Recorded item -> item)) in
  let* () = if List.for_all (fun (item : Attention.item) ->
      Float.is_finite item.received_at && String.equal keeper_name item.keeper_name) external_log
    then Ok () else Error (External_cursor_failed "external counterpart rows do not match their original scope or time") in
  match external_after with
  | Some cursor when cursor < 0 || cursor > List.length external_log ->
    Error (External_cursor_failed "external log shrank behind its admission cursor")
  | Some _ | None -> Ok {keeper_name;after;before;external_after;chat_rows;external_log}

let counterpart_snapshot_to_json (snapshot : counterpart_snapshot) =
  `Assoc ["keeper_name", `String snapshot.keeper_name;
    "after", (match snapshot.after with None -> `Null | Some ts -> `Float ts);
    "before", `Float snapshot.before;
    "external_after", (match snapshot.external_after with None -> `Null | Some value -> `Int value);
    "external_through", `Int (external_through snapshot);
    "chat_rows", `List (List.map Chat.captured_row_to_json snapshot.chat_rows);
    "external_log", `List (List.map Attention.item_to_json snapshot.external_log)]

let counterpart_snapshot_of_json value =
  let fields names = function
    | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
    | _ -> Error "unexpected counterpart snapshot fields" in
  let finite = function
    | `Float value when Float.is_finite value -> Ok value
    | _ -> Error "counterpart time must be finite float" in
  let list decode = function
    | `List values -> List.fold_left (fun result value ->
      let* acc = result in let* value = decode value in Ok (value :: acc)) (Ok []) values
      |> Result.map List.rev
    | _ -> Error "counterpart rows must be a list" in
  (* Existing domain codecs own external shapes. Exact roundtrip additionally
     refuses optional defaults/unknown or duplicate typed fields. Domain string
     association payloads (metadata/address) retain their original entry order. *)
  let item value =
    let* item = Attention.item_of_json value in
    if Float.is_finite item.received_at
       && Yojson.Safe.equal value (Attention.item_to_json item)
    then Ok item else Error "incomplete or unknown external counterpart fields" in
  let* fields = fields ["keeper_name";"after";"before";"external_after";"external_through";"chat_rows";"external_log"] value in
  let get key = List.assoc key fields in
  let* keeper_name = match get "keeper_name" with `String name -> Ok name | _ -> Error "invalid counterpart Keeper" in
  let* after = match get "after" with `Null -> Ok None | value -> Result.map Option.some (finite value) in
  let* before = finite (get "before") in
  let* external_after = match get "external_after" with
    | `Null -> Ok None | `Int value when value >= 0 -> Ok (Some value)
    | _ -> Error "invalid counterpart external offset" in
  let* through = match get "external_through" with `Int value when value >= 0 -> Ok value
    | _ -> Error "invalid counterpart external frontier" in
  let* chat_rows = list Chat.captured_row_of_json (get "chat_rows") in
  let* external_log = list item (get "external_log") in
  let snapshot = {keeper_name;after;before;external_after;chat_rows;external_log} in
  if Option.exists (fun cursor -> cursor > List.length external_log) external_after
     || not (List.for_all (fun row -> selected_chat ~after ~before (Chat.captured_row_message row)) chat_rows)
     || not (List.for_all (fun (item : Attention.item) -> String.equal keeper_name item.keeper_name) external_log)
     || external_through snapshot <> through
  then Error "counterpart snapshot selection or original frontier is inconsistent"
  else Ok snapshot

let capture_counterparts ~external_after ~base_dir ~keeper_name ~after ~before =
  let* snapshot = capture_counterparts_read ~external_after ~base_dir ~keeper_name ~after ~before () in
  let* _ = counterpart_snapshot_of_json (counterpart_snapshot_to_json snapshot)
    |> Result.map_error (fun detail -> External_cursor_failed detail) in
  Ok snapshot

let snapshot_extends ~(original : counterpart_snapshot) ~(current : counterpart_snapshot) =
  let rec prefix same original current = match original, current with
    | [], ([] | _::_) -> true
    | _::_, [] -> false
    | first::rest, next::tail -> same first next && prefix same rest tail in
  if original.keeper_name <> current.keeper_name || original.after <> current.after
     || original.before <> current.before || original.external_after <> current.external_after
  then Error "Current counterpart selection differs from its original coordinates"
  else if not (prefix (fun (left : Attention.item) right -> left=right) original.external_log current.external_log)
  then Error "Original external counterpart prefix changed or disappeared"
  else if not (prefix Chat.captured_row_same_source original.chat_rows current.chat_rows)
  then Error "Original selected chat counterpart prefix changed or disappeared"
  else Ok ()

let validate_original_selection (original : counterpart_snapshot) ~base_dir ~keeper_name =
  if original.keeper_name <> keeper_name then Error (External_cursor_failed "Original counterpart Keeper differs")
  else
    let* current = capture_counterparts_read ?external_after:original.external_after
      ~base_dir ~keeper_name ~after:original.after ~before:original.before () in
    snapshot_extends ~original ~current |> Result.map_error (fun detail -> External_cursor_failed detail)

let counterpart_observations_between ~base_dir ~keeper_name ~after ~before =
  capture_counterparts_read ~base_dir ~keeper_name ~after ~before ()
  |> Result.map counterpart_observations

let counterpart_observations_from ~external_after ~base_dir ~keeper_name ~after ~before =
  capture_counterparts ~external_after ~base_dir ~keeper_name ~after ~before
  |> Result.map (fun snapshot -> counterpart_observations snapshot, external_through snapshot)
;;

let counterpart_observations_between_offloaded ~base_dir ~keeper_name ~after ~before =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    counterpart_observations_between ~base_dir ~keeper_name ~after ~before)
;;

let goal_context_for_task ~config = function
  | None -> Keeper_librarian.No_task
  | Some task ->
    let task_id = Keeper_id.Task_id.to_string task in
    let open Result.Syntax in
    let criteria =
      let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config in
      let ids = List.filter_map (fun (goal_id, tasks) ->
        if List.mem task_id tasks then Some goal_id else None) links in
      let* goals_by_id =
        Result.map_error Goal_store.unavailable_to_string
          (Goal_store.load_goals_by_id_result config)
      in
      List.fold_right (fun id rest ->
        let* rest = rest in
        match Goal_store.Goal_id_map.find_opt id goals_by_id with
        | None -> Error ("Linked Goal is missing: " ^ id)
        | Some goal -> Ok ((id, goal.phase, Goal_store.criterion_of_goal goal) :: rest)) ids (Ok [])
    in
    Keeper_librarian.Task_goals { task_id; criteria }
;;
