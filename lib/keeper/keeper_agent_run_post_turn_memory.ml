(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)

let counterpart_observations_before ~base_dir ~keeper_name ~before =
  Keeper_librarian_input_sources.counterpart_observations_between
    ~base_dir ~keeper_name ~after:None ~before
;;


let counterpart_observations_before_offloaded ~base_dir ~keeper_name ~before =
  Keeper_librarian_input_sources.counterpart_observations_between_offloaded
    ~base_dir ~keeper_name ~after:None ~before
;;

let goal_context_for_task ~config task =
  Keeper_librarian_input_sources.goal_context_for_task ~config task
;;

let run
  ~config
  ~(meta : Keeper_meta_contract.keeper_meta)
  ~turn
  ~agent_core_turn_count
  ~tool_observations
  ~librarian_messages
  ~checkpoint_owner
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
      let run_admitted_librarian ~(live_meta : Keeper_meta_contract.keeper_meta) trigger =
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
            ; goal_context = goal_context_for_task ~config live_meta.current_task_id
            ; keeper_instructions = live_meta.instructions
            ; current = current_selection
            ; working_context = Domain_pool_ref.submit_io_or_inline (fun () ->
                Keeper_librarian_context_io.capture
                  ~base_path:config.Workspace.base_path ~keepers_dir ~keeper_name:meta.name)
            ; messages = librarian_messages
            ; tool_observations
            ; counterpart_observations
            }
          in
          Keeper_librarian_runtime.run_best_effort ~trigger
            ~base_path:config.Workspace.base_path
            ~keepers_dir
            ~keeper_id:meta.name
            ~expected_revision
            librarian_input
      in
      let librarian_series ~meta:live_meta trigger =
        (* Submission is asynchronous. Re-check the same live SSOT at the
           execution boundary so an ON -> OFF/INVALID change while queued
           remains a real kill switch before snapshot I/O or provider work. *)
        match Env_config.KeeperMemoryOs.librarian_config_state () with
        | Disabled | Invalid -> ()
        | Enabled -> run_admitted_librarian ~live_meta trigger
      in
      Keeper_librarian_queue_refresh.remember_turn
        ~base_path:config.Workspace.base_path ~keeper_name:meta.name
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) librarian_series;
      let (_ : Keeper_memory_lane.outcome) =
        Keeper_memory_lane.submit
          ~base_path:config.Workspace.base_path
          ~keeper_name:meta.name
          (fun () -> Keeper_librarian_queue_refresh.run_completed_turn
            ~base_path:config.Workspace.base_path ~keeper_name:meta.name)
      in
      ()
  in
  (match checkpoint_owner with
   | Runtime_execution.Masc_agent_core ->
     Keeper_librarian_queue_refresh.forget_turn
       ~base_path:config.Workspace.base_path
       ~keeper_name:meta.name;
     (match Env_config.KeeperMemoryOs.librarian_config_state () with
      | Disabled | Invalid -> ()
      | Enabled ->
        Keeper_librarian_queue_signal.changed
          ~base_path:config.Workspace.base_path
          ~keeper_name:meta.name)
   | Runtime_execution.Official_client -> submit_librarian_if_enabled ());
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
