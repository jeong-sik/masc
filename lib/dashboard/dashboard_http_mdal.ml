(** Dashboard HTTP MDAL — MDAL loop rendering.

    Extracted from server_dashboard_http.ml. *)


open Server_utils

let mdal_status_string (status : Mdal.status) : string =
  Mdal.status_to_string status

let mdal_iteration_record_json (r : Mdal.iteration_record) : Yojson.Safe.t =
  let evidence_json =
    match r.evidence with
    | None -> `Null
    | Some evidence ->
        `Assoc
          [
            ("worker_engine", `String (Mdal.worker_engine_to_string evidence.engine));
            ("worker_model", `String evidence.model_used);
            ("tool_call_count", `Int evidence.tool_call_count);
            ("tool_names", `List (List.map (fun item -> `String item) evidence.tool_names));
            ("session_id", `String evidence.session_id);
            ("evidence_status", `String (Mdal.evidence_status_to_string evidence.status));
          ]
  in
  `Assoc
    [
      ("iteration", `Int r.iteration);
      ("metric_before", `Float r.metric_before);
      ("metric_after", `Float r.metric_after);
      ("delta", `Float r.delta);
      ("changes", `String r.changes);
      ("failed_attempts", `String r.failed_attempts);
      ("next_suggestion", `String r.next_suggestion);
      ("elapsed_ms", `Int r.elapsed_ms);
      ("cost_usd", Json_util.float_opt_to_json r.cost_usd);
      ("evidence", evidence_json);
    ]

let mdal_loop_json ~(config : Room.config) ~(history_limit : int)
    (state : Mdal.loop_state) : Yojson.Safe.t =
  let history =
    state.history
    |> take history_limit
    |> List.map mdal_iteration_record_json
  in
  let latest_evidence = Mdal.latest_evidence state in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("status", `String (mdal_status_string state.status));
      ("strict_mode", `Bool state.strict_mode);
      ("error_message", Json_util.string_opt_to_json state.error_message);
      ("error_reason", Json_util.string_opt_to_json state.error_message);
      ("stop_reason", Json_util.string_opt_to_json state.stop_reason);
      ("profile", `String state.profile.name);
      ("current_iteration", `Int state.current_iteration);
      ("max_iterations", `Int state.profile.max_iterations);
      ("baseline_metric", `Float state.baseline_metric);
      ("current_metric", `Float (Mdal.current_metric state));
      ("target", `String state.profile.target);
      ("stagnation_streak", `Int state.stagnation_streak);
      ("stagnation_limit", `Int state.profile.stagnation_count);
      ("elapsed_seconds", `Float (Time_compat.now () -. state.start_time));
      ("start_time", `String (iso8601_of_unix state.start_time));
      ("updated_at", `String (iso8601_of_unix state.updated_at));
      ("stopped_at",
       match state.stopped_at with
       | Some ts -> `String (iso8601_of_unix ts)
       | None -> `Null);
      ("execution_mode",
       `String (Mdal.execution_mode_to_string state.execution_mode));
      ("worker_engine",
       match state.worker_engine with
       | Some engine -> `String (Mdal.worker_engine_to_string engine)
       | None -> `Null);
      ("worker_model", Json_util.string_opt_to_json state.worker_model);
      ("evidence_policy", if state.strict_mode then `String "hard" else `String "legacy");
      ("latest_tool_call_count",
       `Int
         (match latest_evidence with
          | Some evidence -> evidence.tool_call_count
          | None -> 0));
      ("latest_tool_names",
       `List
         (match latest_evidence with
          | Some evidence -> List.map (fun item -> `String item) evidence.tool_names
          | None -> []));
      ("session_id",
       match latest_evidence with
       | Some evidence -> `String evidence.session_id
       | None -> `Null);
      ("evidence_status",
       match Mdal.current_evidence_status state with
       | Some status -> `String (Mdal.evidence_status_to_string status)
       | None -> `Null);
      ("durability", `String (Mdal_store.durability config));
      ("persistence_backend", `String (Mdal_store.persistence_backend config));
      ("recoverable", `Bool (Mdal.recoverable state));
      ("history", `List history);
    ]

let parse_mdal_status_filter (raw_opt : string option) : (string option, string) result =
  match raw_opt with
  | None -> Ok None
  | Some raw ->
      let normalized = String.trim raw |> String.lowercase_ascii in
      if normalized = "" then Ok None
      else if normalized = "running"
           || normalized = "interrupted"
           || normalized = "completed"
           || normalized = "stopped"
           || normalized = "error"
      then Ok (Some normalized)
      else
        Error
          (Printf.sprintf
             "invalid status filter: %s (expected running|interrupted|completed|stopped|error)"
             raw)

let mdal_loops_json ~(config : Room.config)
    (request : Httpun.Request.t) : (Yojson.Safe.t, string) result =
  let limit = int_query_param request "limit" ~default:20 |> clamp ~min_v:1 ~max_v:100 in
  let history_limit =
    int_query_param request "history_limit" ~default:50 |> clamp ~min_v:0 ~max_v:500
  in
  match parse_mdal_status_filter (query_param request "status") with
  | Error _ as e -> e
  | Ok status_filter ->
      let loops =
        Tool_mdal.list_loops ~config ()
        |> List.filter (fun (state : Mdal.loop_state) ->
               let status = mdal_status_string state.status in
               match status_filter with
               | None -> true
               | Some expected -> String.equal expected status)
      in
      let loops =
        loops
        |> List.sort (fun (a : Mdal.loop_state) (b : Mdal.loop_state) ->
               let rank (s : Mdal.loop_state) =
                 match s.status with
                 | `Running -> 0
                 | `Interrupted -> 1
                 | _ -> 2
               in
               let by_status = Int.compare (rank a) (rank b) in
               if by_status <> 0 then by_status
               else Float.compare b.start_time a.start_time)
      in
      let total = List.length loops in
      let loops = take limit loops in
      Ok
        (`Assoc
          [
            ("loops", `List (List.map (mdal_loop_json ~config ~history_limit) loops));
            ("total", `Int total);
            ("returned", `Int (List.length loops));
            ("limit", `Int limit);
            ("history_limit", `Int history_limit);
            ("status", Json_util.string_opt_to_json status_filter);
          ])

let mdal_loops_error_json (msg : string) : Yojson.Safe.t =
  `Assoc [ ("error", `String msg) ]
