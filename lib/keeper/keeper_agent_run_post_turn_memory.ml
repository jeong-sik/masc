(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)

let record_librarian_failure ~keeper_name error =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string EpisodeCreateFailures)
    ~labels:[ "keeper", keeper_name; "site", "memory_os_librarian" ]
    ();
  Keeper_librarian_runtime.operation_error_to_string error
;;

let execute_request ~base_path request =
  let keeper_name = Keeper_memory_work_request.keeper_name request in
  try
    let config = Workspace.default_config base_path in
    let meta = Keeper_memory_work_request.meta request in
    let turn = Keeper_memory_work_request.turn request in
    let notes_written =
      Memory.append_from_tool_results
        config
        meta
        ~turn
        ~results:(Keeper_memory_work_request.tool_results request)
    in
    if notes_written > 0
    then
      Keeper_turn_telemetry.log_keeper_memory_write
        ~keeper_name
        ~notes_written
        ~kinds_written:[ "long_term" ];
    let input : Keeper_librarian.input =
      { trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
      ; generation = Keeper_memory_work_request.generation request
      ; messages = Keeper_memory_work_request.librarian_messages request
      }
    in
    let operation : Keeper_librarian_runtime.operation_request =
      { runtime_id = Keeper_memory_work_request.runtime_id request
      ; keeper_id = keeper_name
      ; input
      }
    in
    (match Keeper_librarian_runtime.execute_operation operation with
     | Error error -> Error (record_librarian_failure ~keeper_name error)
     | Ok episode ->
       Log.Keeper.info ~keeper_name
         "memory os librarian wrote episode trace_id=%s generation=%d claims=%d"
         episode.Keeper_memory_os_types.trace_id
         episode.generation
         (List.length episode.claims);
       Ok ())
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MemoryWriteFailures)
      ~labels:[ "keeper", keeper_name ]
      ();
    Error (Printexc.to_string exn)
;;

let drain_keeper ~base_path ~keeper_name =
  match
    Keeper_memory_work_drain.drain
      ~base_path
      ~keeper_name
      ~execute:(execute_request ~base_path)
  with
  | Ok report ->
    Log.Keeper.info ~keeper_name
      "memory owner drain recovered=%d claimed=%d completed=%d failed=%d"
      report.recovered
      report.claimed
      report.completed
      report.failed
  | Error error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", keeper_name; "site", "memory_owner_drain" ]
      ();
    Log.Keeper.error ~keeper_name
      "memory owner drain failed: %s"
      (Keeper_memory_work_drain.error_to_string error)
;;

let schedule_drain ~base_path ~keeper_name =
  Keeper_memory_lane.submit
    ~base_path
    ~keeper_name
    (fun () -> drain_keeper ~base_path ~keeper_name)
;;

let run
  ~(config : Workspace.config)
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
  let deliberation_execution_json =
    Option.map Keeper_deliberation.execution_result_to_json deliberation_execution
  in
  (match
     Keeper_memory_work_request.make
       ~keeper_name:meta.name
       ~generation
       ~turn
       ~runtime_id
       ~meta
       ~tool_results:tool_results_snapshot
       ~librarian_messages
       ~deliberation_execution:deliberation_execution_json
   with
   | Error detail ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DispatchEventFailures)
       ~labels:[ "keeper", meta.name; "site", "memory_work_request" ]
       ();
     Log.Keeper.error ~keeper_name:meta.name
       "memory work request rejected: %s"
       detail
   | Ok request ->
     (match Keeper_memory_work_store.enqueue ~base_path:config.base_path request with
      | Error error ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string DispatchEventFailures)
          ~labels:[ "keeper", meta.name; "site", "memory_work_enqueue" ]
          ();
        Log.Keeper.error ~keeper_name:meta.name
          "memory work durable enqueue failed: %s"
          (Keeper_memory_work_store.error_to_string error)
      | Ok
          ( Keeper_memory_work_store.Enqueued
          | Keeper_memory_work_store.Already_present ) ->
        (match schedule_drain ~base_path:config.base_path ~keeper_name:meta.name with
         | Ok () -> ()
         | Error error ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string DispatchEventFailures)
             ~labels:[ "keeper", meta.name; "site", "memory_owner_drain_admission" ]
             ();
           Log.Keeper.error ~keeper_name:meta.name
             "memory work is durable but owner drain admission failed: %s"
             (Keeper_memory_lane.admission_error_to_string error))));

  (* Delegation projection remains an explicit artifact boundary; it is not a
     Memory work settlement. *)
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
