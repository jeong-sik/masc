let goal_context_for_task ~config = function
  | None -> Keeper_librarian.No_task
  | Some task ->
    let task_id = Keeper_id.Task_id.to_string task in
    let ( let* ) = Result.bind in
    let criteria =
      let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config in
      let ids =
        List.filter_map
          (fun (goal_id, tasks) -> if List.mem task_id tasks then Some goal_id else None)
          links
      in
      let* goals =
        Result.map_error
          Goal_store.unavailable_to_string
          (Goal_store.list_goals_result config ())
      in
      List.fold_right
        (fun id rest ->
           let* rest = rest in
           match List.find_opt (fun (goal : Goal_store.goal) -> String.equal goal.id id) goals with
           | None -> Error ("Linked Goal is missing: " ^ id)
           | Some goal ->
             Ok ((id, goal.phase, Goal_store.criterion_of_goal goal) :: rest))
        ids
        (Ok [])
    in
    Keeper_librarian.Task_goals { task_id; criteria }
;;

type read_error =
  | Chat_store_unreadable of string
  | External_attention_unreadable of string

let read_error_to_string = function
  | Chat_store_unreadable detail -> "keeper chat store is unreadable: " ^ detail
  | External_attention_unreadable detail ->
    "external attention store is unreadable: " ^ detail
;;

let counterpart_observations_between ~base_dir ~keeper_name ~after ~before =
  let ( let* ) = Result.bind in
  let in_range ts =
    ts <= before
    &&
    match after with
    | None -> true
    | Some lower -> ts > lower
  in
  let* user_rows =
    Keeper_chat_store.load_all_result ~base_dir ~keeper_name
    |> Result.map_error (fun detail -> Chat_store_unreadable detail)
  in
  let user_rows =
    user_rows
    |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
      in_range message.ts
      &&
      match message.role, message.speaker with
      | Keeper_chat_store.Role.User, Some _ -> true
      | Keeper_chat_store.Role.User, None
      | Keeper_chat_store.Role.Assistant, _
      | Keeper_chat_store.Role.System, _
      | Keeper_chat_store.Role.Tool, _ -> false)
  in
  let* external_items =
    Keeper_external_attention.load_events_result ~base_path:base_dir ~keeper_name
    |> Result.map_error (fun detail -> External_attention_unreadable detail)
    |> Result.map (List.filter_map (function
      | Keeper_external_attention.Recorded item when in_range item.received_at -> Some item
      | Keeper_external_attention.Recorded _ -> None))
  in
  let external_delivery_keys =
    external_items
    |> List.filter_map (fun (item : Keeper_external_attention.item) ->
      match item.external_message with
      | None -> None
      | Some message -> Some (item.conversation.conversation_id, message.message_id))
  in
  let is_external_duplicate (message : Keeper_chat_store.chat_message) =
    match message.conversation_id, message.external_message_id with
    | Some conversation_id, Some message_id ->
      List.exists
        (fun (external_conversation_id, external_message_id) ->
           String.equal conversation_id external_conversation_id
           && String.equal message_id external_message_id)
        external_delivery_keys
    | None, _ | _, None -> false
  in
  let external_observations =
    List.map
      (fun (item : Keeper_external_attention.item) ->
         item.received_at, Keeper_counterpart_observation.of_external_attention item)
      external_items
  in
  let chat_observations =
    user_rows
    |> List.filter (fun message -> not (is_external_duplicate message))
    |> List.filter_map (fun (message : Keeper_chat_store.chat_message) ->
      Keeper_counterpart_observation.of_chat_message message
      |> Option.map (fun observation -> message.ts, observation))
  in
  external_observations @ chat_observations
  |> List.stable_sort (fun (left_ts, _) (right_ts, _) -> Float.compare left_ts right_ts)
  |> List.map snd
  |> Result.ok
;;

let counterpart_observations_between_offloaded ~base_dir ~keeper_name ~after ~before =
  Domain_pool_ref.submit_io_or_inline (fun () ->
    counterpart_observations_between ~base_dir ~keeper_name ~after ~before)
;;
