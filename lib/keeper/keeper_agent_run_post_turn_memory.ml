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

let run
  ~config
  ~(meta : Keeper_meta_contract.keeper_meta)
  ~turn
  ~agent_core_turn_count
  ~tool_observations
  ~librarian_messages
  ~post_turn_t0
  ~inference_telemetry
  ()
  =
  (* LLM Librarian extraction runs on this Keeper's memory lane (RFC-0257),
     detached from the turn lane. Meta/config are immutable snapshots, so using
     them after the turn returns does not race a later turn. *)
  (* The librarian toggle is owned at this admission boundary. Disabled or
     invalid configuration must not submit a lane unit, read the current
     snapshot, advance cadence, or emit Librarian runtime failures. *)
  let submit_librarian_if_enabled () =
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled | Invalid -> ()
    | Enabled ->
      let keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path
          ~base_path:config.Workspace.base_path
      in
      let run_admitted_librarian () =
        (* Durable chat is the typed source for direct input. Connector
           attention is also read from its producer-owned store so a
           best-effort ambient chat append cannot erase the actor evidence.
           Both reads are bounded and fenced before this turn's post-turn
           timestamp; identity is never recovered from checkpoint prose. *)
        let counterpart_observations =
          counterpart_observations_before_offloaded
            ~base_dir:config.Workspace.base_path
            ~keeper_name:meta.name
            ~before:post_turn_t0
        in
        match
          Domain_pool_ref.submit_io_or_inline (fun () ->
            Keeper_memory_os_current.read_for_keepers_dir
              ~keepers_dir
              ~keeper_id:meta.name)
        with
        | Error detail ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string MemoryOsLibrarianFailures)
            ~labels:[ "keeper", meta.name; "site", "memory_os_current_read" ]
            ();
          Log.Keeper.warn
            ~keeper_name:meta.name
            "memory os librarian skipped: current snapshot unavailable: %s"
            detail
        | Ok current ->
          let current_selection, expected_revision =
            match current with
            | None -> None, None
            | Some snapshot ->
              Some { Keeper_librarian.facts = snapshot.facts }, Some snapshot.revision
          in
          let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
          let librarian_input : Keeper_librarian.input =
            { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
            ; keeper_instructions = meta.instructions
            ; current = current_selection
            ; messages = librarian_messages
            ; tool_observations
            ; counterpart_observations
            }
          in
          Keeper_librarian_runtime.run_best_effort
            ~base_path:config.Workspace.base_path
            ~keepers_dir
            ~keeper_id:meta.name
            ~expected_revision
            librarian_input
      in
      let librarian_series () =
        (* Submission is asynchronous. Re-check the same live SSOT at the
           execution boundary so an ON -> OFF/INVALID change while queued
           remains a real kill switch before snapshot I/O or provider work. *)
        match Env_config.KeeperMemoryOs.librarian_config_state () with
        | Disabled | Invalid -> ()
        | Enabled -> run_admitted_librarian ()
      in
      let (_ : Keeper_memory_lane.outcome) =
        Keeper_memory_lane.submit
          ~base_path:config.Workspace.base_path
          ~keeper_name:meta.name
          librarian_series
      in
      ()
  in
  submit_librarian_if_enabled ();
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
  let counterpart_observations_before = counterpart_observations_before
  let counterpart_observations_before_offloaded = counterpart_observations_before_offloaded
end
