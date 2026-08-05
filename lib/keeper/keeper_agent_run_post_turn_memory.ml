(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)


let run
  ~config
  ~(meta : Keeper_meta_contract.keeper_meta)
  ~generation
  ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
  ~turn
  ~oas_turn_count
  ~actual_tools
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
        match
          Keeper_memory_os_current.read_for_keepers_dir
            ~keepers_dir
            ~keeper_id:meta.name
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
          (* Same persona SSOT as the keeper's own system prompt
             ([Keeper_unified_prompt.build_system_prompt]). Loaded here on
             the memory lane — off the turn path — so the librarian judges
             retention through the identity the keeper currently lives with. *)
          let persona =
            Keeper_types_profile.load_resolved_persona_extended
              ~keeper_name:meta.name
              ~profile_defaults
              ()
          in
          let librarian_input : Keeper_librarian.input =
            { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
            ; generation
            ; persona
            ; current = current_selection
            ; max_recall_fact_bytes =
                Env_config.KeeperMemoryOs.recall_facts_max_bytes ()
            ; messages = librarian_messages
            }
          in
          Keeper_librarian_runtime.run_best_effort
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
          ~lane:Keeper_memory_lane.Librarian
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
     let used_search =
       List.exists (fun t -> t = "keeper_memory_search") actual_tools
     in
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
          ; "oas_turn_count", `Int oas_turn_count
          ; "used_memory_search", `Bool used_search
          ; "post_turn_ms", `Float post_turn_ms
          ]
          @ (match inference_telemetry with
             | Some t ->
               [ ( "inference_telemetry"
                 , Keeper_hooks_oas.inference_telemetry_to_runtime_json t )
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
