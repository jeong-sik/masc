(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)


let run
  ~config
  ~meta
  ~generation
  ~turn
  ~oas_turn_count
  ~response_text
  ~actual_tools
  ~librarian_messages
  ~post_turn_t0
  ~runtime_id
  ~inference_telemetry
  ?deliberation_execution
  ()
  =
  (* RFC-0257: snapshot the per-keeper tool-emission accumulator synchronously
     at turn end, before the memory series detaches onto the memory lane.
     Reading the live accumulator from a detached fiber could fold a later
     turn's emissions into this turn's notes. *)
  let tool_results_snapshot =
    Keeper_tool_emission_hook.snapshot
      (Keeper_tool_emission_hook.accumulator_for_keeper
         meta.Keeper_meta_contract.name)
  in
  (* (1) deterministic write and (2) LLM librarian extraction run on this
     keeper's memory lane (RFC-0257), detached from the turn lane. Both may
     touch the keeper's memory stores; the lane's
     per-keeper mutex serializes them. meta/config are immutable snapshots, so
     using them after the turn returns does not race a later turn.
     See RFC #3646 Section 3: Det/NonDet boundary. *)
  let memory_series () =
  (try
     let notes_written =
       Memory.append_from_tool_results
         config
         meta
         ~turn
         ~results:tool_results_snapshot
     in
     let kinds_written =
       if notes_written > 0 then [ "long_term" ] else []
     in
     if notes_written > 0
     then
       Keeper_turn_telemetry.log_keeper_memory_write
         ~keeper_name:meta.name
         ~notes_written
         ~kinds_written
   with
   | exn ->
     Log.Keeper.error ~keeper_name:meta.name
       "memory_write failed: %s"
       (Printexc.to_string exn);
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string MemoryWriteFailures)
       ~labels:[ "keeper", meta.name ]
       ());

  (* Memory OS librarian extraction: opt-in, provider-backed, best-effort. *)
  let librarian_input : Keeper_librarian.input =
    { trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
    ; generation
    ; messages = librarian_messages
    }
  in
  Keeper_librarian_runtime.run_best_effort
    ~runtime_id
    ~keeper_id:meta.name
    librarian_input;

  (* Advisory delegation request drafts: keep review artifact persistence on the
     same bounded post-turn memory lane as draft-skill projection, not on the
     decision-record append path. *)
  (try
     match deliberation_execution with
     | None -> ()
     | Some execution -> (
       match
         Keeper_delegation_request_store.write_execution_result
           ~base_path:config.base_path
           ~requester:meta.name
           execution
       with
       | Ok [] -> ()
       | Ok stored ->
         Log.Keeper.info ~keeper_name:meta.name
           "delegation_requests wrote=%d dir=%s"
           (List.length stored)
           (Keeper_delegation_request_store.requests_dir
              ~base_path:config.base_path)
       | Error msg ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string DispatchEventFailures)
           ~labels:[ "keeper", meta.name; "site", "delegation_requests" ]
           ();
         Log.Keeper.warn ~keeper_name:meta.name
           "delegation_requests failed: %s"
           msg)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DispatchEventFailures)
       ~labels:[ "keeper", meta.name; "site", "delegation_requests" ]
       ();
     Log.Keeper.warn ~keeper_name:meta.name
       "delegation_requests failed: %s"
       (Printexc.to_string exn));

  in
  (* RFC-0257: detach (1)-(2) onto the per-keeper memory lane. When the executor
     switch is not initialized (tests, early startup) the lane runs them inline,
     so no memory work is lost. *)
  let (_ : Keeper_memory_lane.outcome) =
    Keeper_memory_lane.submit
      ~base_path:config.base_path
      ~keeper_name:meta.name
      memory_series
  in
  (* Post-turn memory recall evidence is logged to decisions.jsonl. *)
  (try
     let used_search =
       List.exists (fun t -> t = "keeper_memory_search") actual_tools
     in
     let recall_eval =
       if used_search
       then (
         (* Use session history (role+content), not the decision memory bank
            (kind+text+priority).  The bank format caused 60 Type_error
            WARN/cycle — every line skipped because [load_history_user_messages]
            expects [role] and [content] fields. *)
         let history_path =
           Keeper_types_support.keeper_history_path config
             (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         in
         let candidates =
           match
             Keeper_memory_recall.load_history_user_messages_result
               ~path:history_path
               ~max_n:50
           with
           | Ok msgs -> msgs
           | Error exn_class ->
             let exn_label =
               Keeper_memory_recall_exn_class.to_label exn_class
             in
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string DispatchEventFailures)
               ~labels:
                 [ "keeper", meta.name; "site", "memory_recall" ]
               ();
             Log.Keeper.warn ~keeper_name:meta.name
               "memory recall history load failed: <error class=%s>"
               exn_label;
             []
         in
         Some
           (Keeper_memory_recall.evaluate_memory_recall
              ~user_message:""
              ~assistant_reply:response_text
              ~candidates))
       else None
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
             | None -> [])
          @ (match recall_eval with
             | Some e ->
               [ "memory_recall_performed", `Bool e.performed
               ; "memory_recall_passed", `Bool e.passed
               ; "memory_recall_score", `Float e.final_score
               ; "memory_recall_candidates", `Int e.candidate_count
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
