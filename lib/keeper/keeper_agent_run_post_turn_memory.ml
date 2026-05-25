(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)

let run
  ~config
  ~meta
  ~memory
  ~turn
  ~oas_turn_count
  ~response_text
  ~actual_tools
  ~state_snapshot
  ~post_turn_t0
  ?provider_filter
  ~cascade_name
  ~inference_telemetry
  ()
  =
  (* Post-turn deterministic memory write.
     Uses meta-based fallback when [STATE] parsing fails.
     See RFC #3646 Section 3: Det/NonDet boundary. *)
  (try
     let notes_written, kinds_written =
       Keeper_memory_bank.append_memory_notes_from_reply
         config
         meta
         ~snapshot:state_snapshot
         ~turn
         ~reply:response_text
         ()
     in
     let tool_result_notes_written =
       if Keeper_tool_emission_hook.masc_tool_emission_enabled ()
       then (
         let tool_results =
           Keeper_tool_emission_hook.(
             snapshot (accumulator_for_keeper meta.name))
         in
         Keeper_memory_bank.append_memory_notes_from_tool_results
           config
           meta
           ~turn
           ~results:tool_results)
       else 0
     in
     let notes_written = notes_written + tool_result_notes_written in
     let kinds_written =
       if
         tool_result_notes_written > 0
         && not (List.mem "long_term" kinds_written)
       then kinds_written @ [ "long_term" ]
       else kinds_written
     in
     if notes_written > 0
     then
       Keeper_turn_telemetry.log_keeper_memory_write
         ~keeper_name:meta.name
         ~notes_written
         ~kinds_written
   with
   | exn ->
     Log.Keeper.error
       "keeper:%s memory_write failed: %s"
       meta.name
       (Printexc.to_string exn);
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_memory_write_failures
       ~labels:[ "keeper", meta.name ]
       ());

  (* Episodic memory: create an episode from [STATE] after
     Agent.run returns, then persist and emit activity through the
     post-run memory adapter. Collaboration learning (Hebbian
     strengthen/weaken) is owned by the task lifecycle path. *)
  Keeper_agent_memory_episode.record_success
    ~config
    ~keeper_name:meta.name
    ~memory
    ~turn
    ~oas_turn_count
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
    ~snapshot:state_snapshot
    ();

  (* Memory bank compaction: dedup + consolidate if over threshold. *)
  (try
     let memory_summarizer =
       Keeper_memory_llm_summary.make
         ?provider_filter
         ~cascade_name
         ~keeper_name:meta.name
         ()
     in
     let compaction =
       Keeper_memory_bank.compact_memory_bank_if_needed
         ?summarizer:memory_summarizer
         config
         meta
     in
     if compaction.performed
     then
       Log.Keeper.info
         "keeper:%s memory_compacted before=%d after=%d dropped=%d"
         meta.name
         compaction.before_notes
         compaction.after_notes
         compaction.dropped_notes
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_dispatch_event_failures
       ~labels:[ "keeper", meta.name; "site", "memory_bank_compaction" ]
       ();
     Log.Keeper.warn
       "keeper:%s cascade=%s compaction failed: %s"
       meta.name
       (Keeper_types.cascade_name_of_meta meta)
       (Printexc.to_string exn));

  (* Post-turn quality metrics — goal alignment + memory recall.
     Logged to decisions.jsonl for feedback loop analysis. *)
  (try
     let goal_score =
       Keeper_memory_recall.goal_alignment_score
         ~meta
         ~user_message:None
         ~assistant_reply:(Some response_text)
     in
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
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_dispatch_event_failures
               ~labels:
                 [ "keeper", meta.name; "site", "memory_recall" ]
               ();
             Log.Keeper.warn
               "keeper:%s memory recall history load failed: <error class=%s>"
               meta.name
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
          ; "goal_alignment", `Float goal_score
          ; ( "tools_used_count"
            , `Int (List.length actual_tools) )
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
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_dispatch_event_failures
       ~labels:[ "keeper", meta.name; "site", "post_turn_eval" ]
       ();
     Log.Keeper.warn
       "keeper:%s post_turn_eval jsonl append failed: %s"
       meta.name
       (Printexc.to_string exn))
;;
