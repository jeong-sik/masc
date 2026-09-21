(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)

let counterpart_observations_before ~base_dir ~keeper_name ~before =
  let user_rows =
    (Keeper_chat_store.load_page
       ~base_dir
       ~keeper_name
       ~before
       ()).messages
    |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
      match message.role, message.speaker with
      | Keeper_chat_store.Role.User, Some _ -> true
      | Keeper_chat_store.Role.User, None
      | Keeper_chat_store.Role.Assistant, _
      | Keeper_chat_store.Role.System, _
      | Keeper_chat_store.Role.Tool, _ -> false)
  in
  let external_items =
    Keeper_external_attention.load_recent_evidence_events
      ~base_path:base_dir
      ~keeper_name
    |> List.filter_map (function
      | Keeper_external_attention.Recorded item when item.received_at < before ->
        Some item
      | Keeper_external_attention.Recorded _ -> None)
  in
  let external_delivery_keys =
    external_items
    |> List.filter_map (fun (item : Keeper_external_attention.item) ->
      match item.external_message with
      | None -> None
      | Some message ->
        Some (item.conversation.conversation_id, message.message_id))
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
  |> List.stable_sort (fun (left_ts, _) (right_ts, _) ->
    Float.compare left_ts right_ts)
  |> List.map snd
;;


let counterpart_observations_before_offloaded ~base_dir ~keeper_name ~before =
  Domain_pool_ref.submit_io_or_inline (fun () ->
    counterpart_observations_before ~base_dir ~keeper_name ~before)
;;

let goal_context_for_task ~config = function
  | None -> Keeper_librarian.No_task
  | Some task ->
    let task_id = Keeper_id.Task_id.to_string task in
    let ( let* ) = Result.bind in
    let criteria =
      let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config in
      let ids = List.filter_map (fun (goal_id, tasks) ->
        if List.mem task_id tasks then Some goal_id else None) links in
      let* goals =
        Result.map_error Goal_store.unavailable_to_string
          (Goal_store.list_goals_result config ())
      in
      List.fold_right (fun id rest ->
        let* rest = rest in
        match List.find_opt (fun (goal : Goal_store.goal) -> String.equal goal.id id) goals with
        | None -> Error ("Linked Goal is missing: " ^ id)
        | Some goal -> Ok ((id, goal.phase, Goal_store.criterion_of_goal goal) :: rest)) ids (Ok [])
    in
    Keeper_librarian.Task_goals { task_id; criteria }
;;

let run
  ~config
  ~(meta : Keeper_meta_contract.keeper_meta)
  ~turn
  ~agent_core_turn_count
  ~checkpoint_owner
  ~post_turn_t0
  ~inference_telemetry
  ()
  =
  (* Both kinds of turn leave their record on disk before this runs -- the
     checkpoint and its end line for an Agent-Core turn, the history fragments
     and an end line for an official-client turn -- and the durable consumer
     reads both from there. The turn hands over nothing else: a remembered
     closure would be a second copy of what the log already says. The
     librarian toggle is owned at this admission boundary: disabled or invalid
     configuration wakes nothing. *)
  (match checkpoint_owner with
   | Runtime_execution.Masc_agent_core | Runtime_execution.Official_client ->
     Keeper_librarian_queue_refresh.forget_turn
       ~base_path:config.Workspace.base_path
       ~keeper_name:meta.name;
     (match Env_config.KeeperMemoryOs.librarian_config_state () with
      | Disabled | Invalid -> ()
      | Enabled ->
        Keeper_librarian_queue_signal.changed
          ~base_path:config.Workspace.base_path
          ~keeper_name:meta.name));
  (* Post-turn timing evidence is logged to decisions.jsonl. The keyword
     recall eval that used to ride along here was removed: it was called
     with an empty user message, so it short-circuited to a constant
     [performed=false] while re-reading 50 history lines per turn. *)
  (try
     let post_turn_ms =
       Keeper_timing.round1
         ((Time_compat.now () -. post_turn_t0) *. 1000.0)
     in
     let eval_json =
       `Assoc
         ([ "ts_unix", `Float (Time_compat.now ())
          ; "event", `String "post_turn_eval"
          ; "keeper_name", `String meta.name
          ; "turn", `Int turn
          ; "agent_core_turn_count", `Int agent_core_turn_count
          ; "post_turn_ms", `Float post_turn_ms
          ]
          @ (match inference_telemetry with
             | Some t ->
               [ ( "inference_telemetry"
                 , Keeper_hooks_agent_core.inference_telemetry_to_runtime_json t )
               ]
             | None -> []))
     in
     Keeper_types_support.append_jsonl_line
       (Keeper_types_support.keeper_decision_log_path
          config
          meta.name)
       eval_json
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DispatchEventFailures)
       ~labels:[ "keeper", meta.name; "site", "post_turn_eval" ]
       ();
     Log.Keeper.warn ~keeper_name:meta.name
       "post_turn_eval jsonl append failed: %s"
       (Printexc.to_string exn))
;;

module For_testing = struct
  let goal_context_for_task = goal_context_for_task
  let counterpart_observations_before = counterpart_observations_before
  let counterpart_observations_before_offloaded = counterpart_observations_before_offloaded
end
