(** Keeper HTTP API handlers — POST handlers + GET sub-routes.

    POST handlers extracted to [Server_dashboard_http_keeper_api_post]
    (godfile decomp). *)

include Server_dashboard_http_keeper_api_post

module Limits = Server_dashboard_http_keeper_read_limits

let handle_keeper_paused_work_post =
  Server_dashboard_http_keeper_paused_work.handle_post
;;

let keeper_composite_cache_ttl_s = 5.0
let keeper_file_changes_cache_ttl_s = 10.0

let keeper_file_changes_cache_key ~masc_root ~keeper_name ~window_hours =
  (* Keep the exact effective window and field boundaries. Display rounding
     must not merge distinct reads, nor may a path contain key separators. *)
  "keeper:file-changes:" ^ Yojson.Safe.to_string (`List [
    `String masc_root;
    `String keeper_name;
    `String (Printf.sprintf "%h" window_hours);
    `Int (Keeper_tool_call_log.committed_revision ~keeper_name);
  ])
;;

(* [/file-changes] answers over a trailing time window rather than a row count.

   A count was tried first and could not say what it had covered:
   [Keeper_tool_call_log.read_recent] fills [n] rows for one keeper by scanning
   a multiple of [n] fleet rows, so asking for 500 of one keeper's calls
   returned 454 on 2026-08-24 and asking for 5,000 returned 1,409 -- and a
   caller cannot tell a keeper that made no more calls from a scan that
   stopped short.
   [read_window] has no row cap, so everything in the window is in the answer
   and the window is a fact the response can state.

   The ceiling is what the read costs, not what the log keeps. [read_window]
   parses every row in the date files the window touches, so the cost is a
   straight line in days: measured against a server holding 2026-08-22..24,
   one keeper's changes took 4.4s over 24h, 8.3s over 48h and 11.0s over 72h.
   The log retains 30 days, and asking for all of them would be about two
   minutes inside one request. Three days is what an operator can wait for.
   Reading further back is a different feature and wants an index, not a
   wider scan. *)
let file_changes_default_window_hours = 24.0
let file_changes_max_window_hours = 72.0

let keeper_metrics_response ~config ~keeper_name req =
  let error status code detail =
    status, `Assoc [ "keeper", `String keeper_name
                  ; "code", `String code; "error", `String detail ]
  in
  if not (Keeper_config.validate_name keeper_name) then
    error `Bad_request "invalid_keeper_name" "invalid keeper name"
  else
    let limit_parameters =
      Uri.query (Uri.of_string req.Httpun.Request.target)
      |> List.filter (fun (name, _) -> String.equal name "limit")
    in
    (* Preserve the existing Dashboard's fixed read window. A query cannot
       turn one selected chart into an unbounded ledger scan. *)
    let limit = 120 in
    if limit_parameters <> [] then
      error `Bad_request "invalid_metrics_limit" "the metrics window is fixed at 120 rows"
    else
      let reading =
        Eio_guard.with_named_switch "keeper-metrics-tail" (fun () ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            try
              let store = Keeper_types_support.keeper_metrics_store config keeper_name in
              Dated_jsonl.read_recent_result store limit
              |> Result.map_error Dated_jsonl.read_error_to_string
            with
            | Sys_error detail -> Error detail
            | Unix.Unix_error (cause, operation, path) ->
              Error (Printf.sprintf "%s %s: %s" operation path (Unix.error_message cause))))
      in
      match reading with
      | Error detail -> error `Service_unavailable "metrics_store_unavailable" detail
      | Ok entries ->
        let scanned_rows = List.length entries in
        let parsed_metrics = List.filter_map (function
          | Dated_jsonl.Parsed row -> Some row
          | Dated_jsonl.Malformed_json _ -> None) entries in
        let series, window_summary =
          Dashboard_http_keeper_detail.compute_metrics_window
            ~parsed_metrics ~series_points:limit
        in
        (* The projection counts accepted turns and heartbeats. Compare that
           count with physical coverage, so malformed and retired rows remain
           visible as skipped instead of looking like an empty history. *)
        match Json_util.assoc_member_opt "sample_points" window_summary with
        | Some (`Int accepted_rows) when accepted_rows >= 0 && accepted_rows <= scanned_rows ->
          `OK, `Assoc
            [ "keeper", `String keeper_name
            ; "series", `List series
            ; "window_summary", window_summary
            ; "scanned_rows", `Int scanned_rows
            ; "skipped_rows", `Int (scanned_rows - accepted_rows)
            ; "limit", `Int limit
            ]
        | _ ->
          error `Service_unavailable "metrics_projection_invalid"
            "metrics projection row count disagrees with the read window"
;;

let cached_assoc_body_or_self cached fields =
  match List.assoc_opt "body" fields with
  | Some body -> body
  | None -> cached
;;

let cached_keeper_runtime_trace_json config name ?trace_id ?turn_id ~limit () =
  let cache_key =
    keeper_runtime_trace_cache_key config name ?trace_id ?turn_id ~limit ()
  in
  let cached =
    Dashboard_cache.get_or_compute cache_key ~ttl:Limits.keeper_hot_path_cache_ttl_s @@ Pool_work.cpu ~name:__FUNCTION__ (fun () ->
      let status, body =
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          keeper_runtime_trace_json config name ?trace_id ?turn_id ~limit ())
      in
      `Assoc
        [ ( "status"
          , `String
              (match status with
               | `OK -> "ok"
               | `Not_found -> "not_found") )
        ; "body", body
        ])
  in
  match cached with
  | `Assoc fields ->
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String "not_found") -> `Not_found
      | _ -> `OK
    in
    let body = cached_assoc_body_or_self cached fields in
    status, body
  | other -> `OK, other
;;

let cached_keeper_config_json config name =
  (* The response carries the manifest's content revision used by config CAS.
     A TTL cache could hand an editor a superseded token after masc_keeper_up
     or another in-process writer commits, so this authority-bearing endpoint
     always reads the current bytes. *)
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    Dashboard_http_keeper.keeper_config_json config name)
;;

let offline_keeper_composite_json ~config name (m : Keeper_meta_contract.keeper_meta) =
  let now = Time_compat.now () in
  let phase, attention_state =
    if m.paused
    then "paused", Server_dashboard_http_composite_claims.Attention_paused
    else "offline", Server_dashboard_http_composite_claims.Attention_offline
  in
  let reason =
    if m.paused then "paused_without_registry_entry" else "registry_absent"
  in
  let secret_projection =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:config.Workspace.base_path
      ~keeper_name:name
  in
  `Assoc
    [ "keeper", `String name
    ; "correlation_id", `String (Printf.sprintf "keeper:%s:offline" name)
    ; "run_id", `String (Printf.sprintf "keeper:%s:offline" name)
    ; "ts", `Float now
    ; "phase", `String phase
    ; "turn_phase", `String "idle"
    ; "decision", `Assoc [ "stage", `String "idle" ]
    ; "runtime", `Assoc [ "state", `String "offline" ]
    ; "measurement", `Assoc [ "captured", `Bool false ]
    ; ( "invariants"
      , `Assoc
          [ "event_priority_monotone", `Bool true
          ; "phase_derivation_agreement", `Bool true
          ] )
    ; "is_live", `Bool false
    ; "live_turn", `Null
    ; "last_outcome", `Null
    ; "idle_seconds", `Int 0
    ; "last_turn_ts", `Float m.runtime.usage.last_turn_ts
    ; "fsm_guard_violations", `Int 0
    ; "fsm_guard_violation_breakdown", `List []
    ; "secret_projection", secret_projection
    ; ( "runtime_attention"
      , `Assoc
          [ ( "state"
            , `String
                (Server_dashboard_http_composite_claims.runtime_attention_state_to_wire
                   attention_state) )
          ; "needs_attention", `Bool true
          ; "blocked", `Bool false
          ; "fiber_stop_requested", `Bool false
          ; "reason", `String reason
          ; "raw_phase", `String phase
          ; "is_live", `Bool false
          ; "source", `String "offline_composite_fallback"
          ; "execution_current", `Bool false
          ; "stale_execution_receipt", `Bool false
          ; "live_turn_started_at", `Null
          ; "live_turn_last_progress_at", `Null
          ] )
    ; "recommended_actions", `List []
    ]
;;

let keeper_composite_status_to_string = function
  | `OK -> "ok"
  | `Not_found -> "not_found"
  | `Internal_server_error -> "internal_server_error"
;;

let keeper_composite_status_of_string_opt = function
  | "ok" -> Some `OK
  | "not_found" -> Some `Not_found
  | "internal_server_error" -> Some `Internal_server_error
  | _ -> None
;;

let cached_keeper_composite_json config name =
  let cache_key = keeper_composite_cache_key ~base_path:config.Workspace.base_path name in
  let cached =
    Dashboard_cache.get_or_compute cache_key ~ttl:keeper_composite_cache_ttl_s @@ Pool_work.cpu ~name:__FUNCTION__ (fun () ->
      let status, body =
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          match Keeper_registry.get ~base_path:config.base_path name with
          | Some entry ->
            `OK, Server_dashboard_http.dashboard_keeper_composite_json ~config entry
          | None ->
            (match Keeper_meta_store.read_meta config name with
             | Error e -> `Internal_server_error, error_json e
             | Ok None ->
               ( `Not_found
               , error_json (Printf.sprintf "keeper %S not found" name) )
             | Ok (Some m) -> `OK, offline_keeper_composite_json ~config name m))
      in
      `Assoc
        [ "status", `String (keeper_composite_status_to_string status)
        ; "body", body
        ])
  in
  match cached with
  | `Assoc fields ->
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String value) ->
        (match keeper_composite_status_of_string_opt value with
         | Some status -> status
         | None -> `Internal_server_error)
      | _ -> `Internal_server_error
    in
    let body = cached_assoc_body_or_self cached fields in
    status, body
  | other -> `OK, other
;;

module Route = Server_dashboard_http_keeper_get_route
module Chat_history = Server_dashboard_http_keeper_chat_history
module Tool_calls = Server_dashboard_http_keeper_tool_calls
module Memory_reads = Server_dashboard_http_keeper_memory_reads
module Turn_reads = Server_dashboard_http_keeper_turn_reads
module Trace_reads = Server_dashboard_http_keeper_trace_reads
module Prompt_reads = Server_dashboard_http_keeper_prompt_reads

let keeper_get_permission ?include_thinking path =
  Option.bind (Route.of_path path) (Route.permission ?include_thinking)
;;

let handle_keeper_get_subroutes state req request reqd =
  match Route.of_path (Http.Request.path req) with
  | Some Route.(Keeper (Metrics, name)) -> (
    let status, json =
      keeper_metrics_response ~config:(Mcp_server.workspace_config state)
        ~keeper_name:name req
    in
    Http.Response.json_value_on_cpu ~status ~request
      ~extra_headers:(Server_auth.cors_headers (Server_auth.get_origin request))
      json reqd)
  | Some Route.(Keeper (Github_identity, name)) -> (
    if not (Keeper_config.validate_name name) then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else
      let config = Mcp_server.workspace_config state in
      (* Effective meta: the lane is chosen by the TOML-owned
         [sandbox_profile], which a persisted read answers with the default. *)
      match Keeper_meta_store.read_effective_meta config name with
      | Error message ->
        Server_auth.respond_json_value_with_cors ~status:`Internal_server_error request reqd
          (error_json message)
      | Ok None ->
        Server_auth.respond_json_value_with_cors ~status:`Not_found request reqd
          (error_json (Printf.sprintf "keeper %S not found" name))
      | Ok (Some meta) ->
        let hostname =
          match Server_utils.query_param req "hostname" with
          | Some hostname -> hostname
          | None -> Keeper_github_identity.default_hostname
        in
        (match Keeper_github_login_lane.observe ~config ~meta ~hostname with
         | Error message ->
           Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
             (error_json message)
         | Ok observation ->
           Server_auth.respond_json_value_with_cors ~status:`OK request reqd
             (Keeper_github_identity.observation_to_yojson observation)))
  | Some Route.(Keeper (Board_attention_quarantines, name)) -> (
    (* One Keeper's rows of the inventory the operator snapshot already serves
       for the fleet, under the same public-read policy: same rows, same
       gate. The snapshot only builds them with [include_keepers], which the
       TUI's summary read turns off, so a Keeper detail asks here instead. *)
    if not (Keeper_config.validate_name name) then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else
      let config = Mcp_server.workspace_config state in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (Keeper_board_attention_quarantine_command.inventory_json
           ~base_path:config.Workspace.base_path
           ~keeper_names:[ name ]))
  | Some Route.(Keeper (Chat_history_page, name)) ->
    Chat_history.handle_page_get state req request reqd name
  | Some Route.(Keeper (Chat_initial_reply, name)) ->
    Chat_history.handle_initial_reply_get state request reqd name
  | Some Route.(Keeper (Chat_history, name)) ->
    Chat_history.handle_get state request reqd name
  | Some Route.(Keeper (Checkpoints, name)) -> (
    let (st, json) = keeper_checkpoint_inventory_json (Mcp_server.workspace_config state) name in
    let status : Httpun.Status.t =
      match st with `OK -> `OK | `Not_found -> `Not_found
    in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd)
  | Some Route.(Keeper (File_changes, name)) -> (
    if not (Keeper_config.validate_name name) then
      (* A name that cannot belong to a keeper is refused rather than looked
         up. The window filters rows by an equal string, so a typo would
         otherwise come back as an empty answer -- indistinguishable from a
         real keeper that changed nothing. *)
      respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
    else
      (* A window that cannot be read is refused, not replaced by the default.
         Answering [?window_hours=abc] over the last day would report a period
         the caller did not ask for, under a field saying it did. Too wide a
         window is different: it is clamped, and the response states the
         window it actually covered. *)
      match
        match Server_utils.query_param req "window_hours" with
        | None -> Ok file_changes_default_window_hours
        | Some raw -> (
            match float_of_string_opt (String.trim raw) with
            | Some hours when hours > 0.0 ->
                Ok (Float.min hours file_changes_max_window_hours)
            | Some _ | None ->
                Error (Printf.sprintf "window_hours must be a positive number: %s" raw))
      with
      | Error detail -> respond_error reqd detail
      | Ok window_hours ->
      let config = Mcp_server.workspace_config state in
      let masc_root = Workspace.masc_dir config in
      let cache_key =
        keeper_file_changes_cache_key ~masc_root ~keeper_name:name ~window_hours
      in
      let payload =
        Dashboard_cache.get_or_compute_payload
          cache_key
          ~ttl:keeper_file_changes_cache_ttl_s
          (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            (* Folds what the store gained since the last call rather than reading
               the window again: this route answered 1.8-8.8s per call on
               2026-09-06 and was the profile's top allocator. *)
            let tally =
              Keeper_tool_call_log.file_change_tally
                ~keeper_name:name
                ~window_hours
                ()
            in
            `Assoc
              [ ("keeper", `String name)
                (* The window this answer covers, and how many of the keeper's
                   calls fell inside it. Both are stated because the changes alone
                   do not say what was looked at: no changes in an hour and no
                   calls in an hour are different facts. *)
              ; ("window_hours", `Float window_hours)
                (* From the tally, not the row list: the three outcomes partition
                   what was read, and a caller that folds rows as it reads them
                   does not keep the list to measure. *)
              ; ( "calls_in_window"
                , `Int (Keeper_tool_call_file_change.rows_counted tally) )
              ; ( "changes"
                , `List
                    (List.map
                       Keeper_tool_call_file_change.to_json
                       tally.Keeper_tool_call_file_change.changes) )
                (* Both counts ride the answer rather than a log line. A reader
                   drawing changes has to be able to say that a turn wrote more
                   than it can show: over_budget rows are changes whose text the
                   log did not keep. *)
              ; ("over_budget", `Int tally.Keeper_tool_call_file_change.over_budget)
              ; ("malformed", `Int tally.Keeper_tool_call_file_change.malformed)
              ]))
      in
      Server_cached_read_http.respond ~request:req reqd payload)
  | Some Route.(Keeper (Paused_work, _)) ->
    Server_dashboard_http_keeper_paused_work.handle_get state req reqd
  | Some Route.(Keeper (Runtime_trace, name)) -> (
    let trace_id = Server_utils.query_param req "trace_id" in
    let turn_id =
      match Server_utils.query_param req "turn_id" with
      | Some raw -> int_of_string_opt (String.trim raw)
      | None -> None
    in
    let limit =
      Server_utils.int_query_param req "limit" ~default:200
      |> max 1 |> min Limits.trajectory_max_limit
    in
    let st, json =
      cached_keeper_runtime_trace_json (Mcp_server.workspace_config state) name
        ?trace_id ?turn_id ~limit ()
    in
    let status : Httpun.Status.t =
      match st with `OK -> `OK | `Not_found -> `Not_found
    in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd)
  | Some Route.(Keeper (Config, name)) -> (
    let config = (Mcp_server.workspace_config state) in
    let (st, json) =
      cached_keeper_config_json config name
    in
    let status : Httpun.Status.t =
      match st with `OK -> `OK | `Not_found -> `Not_found
    in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd)
  | Some Route.(Keeper (Tool_stats, name)) ->
    Tool_calls.handle_stats_get state req reqd name
  | Some Route.(Keeper (Tool_result, keeper)) ->
    Tool_calls.handle_result_get state req reqd keeper
  | Some Route.(Keeper (Tool_calls, name)) ->
    Tool_calls.handle_calls_get state req reqd name
  | Some Route.(Keeper (Waiting_inventory, name)) -> (
    if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [ ("error", `String (Printf.sprintf "invalid keeper name: %s" name)) ])
        reqd
    else
      let expected_instances = Httpun.Headers.get_multi req.headers Sse_wire.instance_header in
      let result = Server_observer_scope.read_if_current ~state ~expected_instances
        ~read:(fun config ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            Server_keeper_waiting_inventory.dashboard_json_for_keeper
              config ~keeper_name:name)) in
      (match result with
       | Ok (instance, json) ->
         Http.Response.json_value ~compress:true ~request:req
           ~extra_headers:[Sse_wire.instance_header, instance] json reqd
       | Error error ->
         let status, code = match error with
           | Server_observer_scope.Ambiguous_instance -> `Bad_request, "observer_instance_ambiguous"
           | Instance_mismatch | Scope_changed -> `Conflict, "observer_instance_changed" in
         Http.Response.json_value ~status ~request:req
           (`Assoc ["code", `String code; "error", `String "observer generation unavailable"]) reqd))
  | Some Route.(Keeper (Feedback, name)) -> (
    (* keeper-v2 #9: aggregated response-feedback tally (read API).
       GET /api/v1/keepers/:name/feedback. The per-keeper feedback log is the
       SSOT; the view renders this tally (no view-side derivation). A read IO
       fault surfaces as 500, never a silently-empty success. *)
    if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [ ("error", `String (Printf.sprintf "invalid keeper name: %s" name)) ])
        reqd
    else
      let config = Mcp_server.workspace_config state in
      (match Keeper_response_feedback.read_tally ~config ~keeper_id:name with
       | Ok tally ->
         Http.Response.json_value ~compress:true ~request:req
           (Keeper_response_feedback.tally_to_json tally) reqd
       | Error (`Io msg) ->
         Http.Response.json_value ~status:`Internal_server_error
           (`Assoc [ ("error", `String msg) ]) reqd))
  | Some Route.(Keeper (Working_context, name)) ->
    Memory_reads.handle_working_context_get state req reqd name
  | Some Route.(Keeper (Memory_facts, name)) ->
    Memory_reads.handle_facts_get state req reqd name
  | Some Route.(Keeper (Memory_journal, name)) ->
    Memory_reads.handle_journal_get state req reqd name
  | Some Route.(Keeper (Operator_note, name)) -> (
    (* RFC-0366. Read-only here: the operator asks whether a note is pending or
       which turn consumed it. The write surface belongs to the operator control
       plane and is a separate change. *)
    (match
       Keeper_operator_note.read ~config:(Mcp_server.workspace_config state) ~keeper:name
     with
     | Ok note ->
       Http.Response.json_value ~compress:true ~request:req
         (`Assoc
            [ "keeper", `String name
            ; "dashboard_surface", `String "/api/v1/keepers/:name/operator-note"
            ; "pending", `Bool (Option.is_none note.consumed_at)
            ; "note", Keeper_operator_note.to_json note
            ])
         reqd
     | Error (Keeper_operator_note.No_note as error) ->
       Http.Response.json_value ~status:`Not_found
         (`Assoc
            [ "error", `String (Keeper_operator_note.read_error_to_string error) ])
         reqd
     | Error
         ((Keeper_operator_note.Read_unknown_keeper _
          | Keeper_operator_note.Malformed _) as error) ->
       Http.Response.json_value ~status:`Bad_request
         (`Assoc
            [ "error", `String (Keeper_operator_note.read_error_to_string error) ])
         reqd))
  | Some Route.(Keeper (Next_request, name)) -> (
    (* What the next Agent Core request would carry, computed from the values
       a turn uses and nothing a turn owns: no dispatch, no cursor, no note. *)
    (match
       Keeper_next_request_forecast.forecast
         ~config:(Mcp_server.workspace_config state)
         ~keeper_name:name
     with
     | Ok forecast ->
       Http.Response.json_value ~compress:true ~request:req
         (match Keeper_next_request_forecast.to_json forecast with
          | `Assoc fields ->
            `Assoc
              (("dashboard_surface", `String "/api/v1/keepers/:name/next-request")
               :: fields)
          | json -> json)
         reqd
     | Error detail ->
       Http.Response.json_value ~status:`Not_found
         (`Assoc [ "error", `String detail ])
         reqd))
  | Some Route.(Keeper (Last_prompt, name)) ->
    Prompt_reads.handle_last_prompt_get state req reqd name
  | Some Route.(Keeper (Provider_input_continuity, name)) ->
    Prompt_reads.handle_provider_input_continuity_get state req reqd name
  | Some Route.(Keeper (Provider_input_part, name)) ->
    Prompt_reads.handle_provider_input_part_get state req reqd name
  | Some Route.(Keeper (Provider_input, name)) ->
    Prompt_reads.handle_provider_input_manifest_get state req reqd name
  | Some Route.(Keeper (Raw_traces, name)) ->
    Trace_reads.handle_raw_traces_get state req reqd name
  | Some Route.(Keeper (Raw_trace, name)) ->
    Trace_reads.handle_raw_trace_get state req reqd name
  | Some Route.(Keeper (Turn_records, name)) ->
    Turn_reads.handle_records_get state req reqd name
  | Some Route.(Keeper (Turn_transcript, name)) ->
    Turn_reads.handle_transcript_get state req reqd name
  | Some Route.(Keeper (Trajectory, name)) ->
    Trace_reads.handle_trajectory_get state req reqd name
  | Some Route.(Keeper (Transitions, name)) -> (
    let limit =
      Server_utils.int_query_param req "limit" ~default:20
      |> max 1 |> min 50
    in
    let base_path = (Mcp_server.workspace_config state).base_path in
    let phase = Keeper_registry.get_phase ~base_path name in
    let phase_str = match phase with
      | Some p -> `String (Keeper_state_machine.phase_to_string p)
      | None -> `Null
    in
    let transitions =
      Keeper_transition_audit.recent_transitions_json
        ~keeper_name:name ~limit
    in
    let json = `Assoc [
      "keeper", `String name;
      "current_phase", phase_str;
      "count", `Int (json_list_length transitions);
      "transitions", transitions;
    ] in
    Http.Response.json_value ~compress:true ~request:req json reqd)
  (* #12798 Dashboard Gaps: lifecycle event timeline per keeper. *)
  | Some Route.(Keeper (Lifecycle, name)) ->
    let limit =
      Server_utils.int_query_param req "limit" ~default:50
      |> max 1 |> min 200
    in
    let events =
      Keeper_lifecycle_audit.recent_json ~keeper_name:name ~limit
    in
    let json = `Assoc [
      "keeper", `String name;
      "count", `Int (json_list_length events);
      "events", events;
    ] in
    Http.Response.json_value ~compress:true ~request:req json reqd
  | Some Route.(Keeper (Eval, name)) -> (
    let base_path = (Mcp_server.workspace_config state).base_path in
    let limit =
      Server_utils.int_query_param req "limit" ~default:10
      |> max 1 |> min 100
    in
    let snapshots =
      Dashboard_eval_feed.read_latest ~base_path ~agent_name:name ~limit
    in
    let latest_verdict =
      match snapshots with
      | s :: _ -> Some s.Dashboard_eval_feed.verdict
      | [] -> None
    in
    let json = `Assoc [
      ("keeper", `String name);
      ("count", `Int (List.length snapshots));
      ("latest_coverage",
        match latest_verdict with
        | Some v -> `Float v.Dashboard_eval_feed.coverage
        | None -> `Null);
      ("latest_all_passed",
        match latest_verdict with
        | Some v -> `Bool v.Dashboard_eval_feed.all_passed
        | None -> `Null);
      ("snapshots",
        `List (List.map Dashboard_eval_feed.snapshot_to_json snapshots));
    ] in
    Http.Response.json_value ~compress:true ~request:req json reqd)
  | Some Route.(Keeper (State_diagram, name)) -> (
    let base_path = (Mcp_server.workspace_config state).base_path in
    let phase = Keeper_registry.get_phase ~base_path name in
    let current = match phase with Some p -> p | None -> Keeper_state_machine.Offline in
    let mermaid = Keeper_state_machine_mermaid.phase_to_mermaid ~current in
    let phase_str = Keeper_state_machine.phase_to_string current in
    let json =
      `Assoc
        [ "keeper", `String name
        ; "current_phase", `String phase_str
        ; "mermaid", `String mermaid
        ]
    in
    Http.Response.json_value ~compress:true ~request:req json reqd)
  | Some Route.Fleet_composite ->
    (* LT-16a: fleet-wide composite snapshot. Enumerates every
       registered keeper via [Keeper_registry.all] and projects each
       through [Keeper_composite_observer.observe]. Same purity
       contract as the per-keeper route below.

       Shape:
         { "generated_at": 1234567890.1,
           "count": 3,
           "snapshots": [ <snapshot JSON>, ... ] }

       Consumed by [dashboard/src/components/fleet-fsm-matrix.ts]
       (LT-16b, upcoming). *)
    let json =
      Server_dashboard_http.dashboard_fleet_composite_json
        ~config:(Mcp_server.workspace_config state) ()
    in
    Http.Response.json_value ~compress:true ~request:req json reqd
  | Some Route.(Keeper (Composite, name)) -> (
    (* RFC-0003 §7: composite lifecycle snapshot derived from the
       registry entry via the [Keeper_composite_observer] pure
       projection. No mutation, no I/O, no provider/token access. *)
    let config = Mcp_server.workspace_config state in
    let status, json = cached_keeper_composite_json config name in
    let status : Httpun.Status.t =
      match status with
      | `OK -> `OK
      | `Not_found -> `Not_found
      | `Internal_server_error -> `Internal_server_error
    in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd)
  | None ->
    respond_error ~status:`Not_found reqd "not found"
