let log_post_turn_eval
      ~config
      ~(meta : Keeper_types.keeper_meta)
      ~manifest_keeper_turn_id
      ~oas_turn_count
      ~response_text
      ~actual_keeper_tool_names
      ~post_turn_t0
      ~telemetry
  =
  try
    let goal_score =
      Keeper_memory_recall.goal_alignment_score
        ~meta
        ~user_message:None
        ~assistant_reply:(Some response_text)
    in
    let used_search =
      List.exists
        (fun t -> t = "keeper_memory_search")
        actual_keeper_tool_names
    in
    let recall_eval =
      if used_search
      then (
        let bank_path =
          Keeper_types_support.keeper_memory_bank_path config meta.name
        in
        let candidates =
          try
            Keeper_memory_recall.load_history_user_messages
              ~path:bank_path
              ~max_n:50
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_dispatch_event_failures
              ~labels:[ "keeper", meta.name; "site", "memory_recall" ]
              ();
            Log.Keeper.warn
              "keeper:%s memory recall history load failed: %s"
              meta.name
              (Printexc.to_string exn);
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
      Keeper_timing.round1 ((Time_compat.now () -. post_turn_t0) *. 1000.0)
    in
    let eval_json =
      `Assoc
        ([ "ts_unix", `Float (Time_compat.now ())
         ; "event", `String "post_turn_eval"
         ; "keeper_name", `String meta.name
         ; "turn", `Int manifest_keeper_turn_id
         ; "oas_turn_count", `Int oas_turn_count
         ; "goal_alignment", `Float goal_score
         ; "tools_used_count", `Int (List.length actual_keeper_tool_names)
         ; "used_memory_search", `Bool used_search
         ; "post_turn_ms", `Float post_turn_ms
         ]
         @ (match telemetry with
            | Some t ->
              [ "inference_telemetry", Keeper_hooks_oas.inference_telemetry_to_runtime_json t ]
            | None -> [])
         @
         match recall_eval with
         | Some e ->
           [ "memory_recall_performed", `Bool e.performed
           ; "memory_recall_passed", `Bool e.passed
           ; "memory_recall_score", `Float e.final_score
           ; "memory_recall_candidates", `Int e.candidate_count
           ]
         | None -> [])
    in
    Keeper_types_support.append_jsonl_line
      (Keeper_types_support.keeper_decision_log_path config meta.name)
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
      (Printexc.to_string exn)
;;
