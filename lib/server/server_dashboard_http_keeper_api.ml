(** Keeper HTTP API handlers — POST handlers + GET sub-routes.

    POST handlers extracted to [Server_dashboard_http_keeper_api_post]
    (godfile decomp). *)

include Server_dashboard_http_keeper_api_post

let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let freshness_slo_s = Server_dashboard_http_core_cache.freshness_slo_s

(* Maximum number of trajectory/trace entries returned per query. *)
let trajectory_max_limit = 500

let handle_keeper_get_subroutes state req request reqd =
  let req_path = Http.Request.path req in
  let prefix = keeper_api_prefix in
  let plen = String.length prefix in
  let tlen = String.length req_path in
  let ends_with suffix =
    let slen = String.length suffix in
    tlen > plen + slen
    && String.sub req_path (tlen - slen) slen = suffix
  in
  let extract_name suffix =
    let slen = String.length suffix in
    String.trim (String.sub req_path plen (tlen - plen - slen))
  in
  if ends_with "/chat/history" then
    let name = extract_name "/chat/history" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else
      let base_dir = (Mcp_server.workspace_config state).base_path in
      let messages =
        Keeper_chat_store.load ~base_dir ~keeper_name:name
      in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (Keeper_chat_store.to_json_array messages)
  else if ends_with "/person-notes" then
    (* RFC-0229 P2: keeper-authored person notes for the roster pane.
       Read-only fold over the notes store; same shape as the tool
       surface ([{speaker_id, note}]). *)
    let name = extract_name "/person-notes" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else
      let base_dir = (Mcp_server.workspace_config state).base_path in
      let notes = Keeper_person_notes.notes ~base_dir ~keeper_name:name in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (`List
          (List.map
             (fun (speaker_id, note) ->
               `Assoc
                 [ ("speaker_id", `String speaker_id)
                 ; ("note", `String note)
                 ])
             notes))
  else if ends_with keeper_suffix_checkpoints then
    let name = extract_name keeper_suffix_checkpoints in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let (st, json) = keeper_checkpoint_inventory_json (Mcp_server.workspace_config state) name in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with keeper_suffix_runtime_trace then
    let name = extract_name keeper_suffix_runtime_trace in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let trace_id = Server_utils.query_param req "trace_id" in
      let turn_id =
        match Server_utils.query_param req "turn_id" with
        | Some raw -> int_of_string_opt (String.trim raw)
        | None -> None
      in
      let limit =
        Server_utils.int_query_param req "limit" ~default:200
        |> max 1 |> min trajectory_max_limit
      in
      let st, json =
        keeper_runtime_trace_json (Mcp_server.workspace_config state) name
          ?trace_id ?turn_id ~limit ()
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with "/config" then
    let name = extract_name "/config" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let config = (Mcp_server.workspace_config state) in
      let (st, json) =
        Dashboard_http_keeper.keeper_config_json config name
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with keeper_suffix_bdi_snapshot then
    let name = extract_name keeper_suffix_bdi_snapshot in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let config = (Mcp_server.workspace_config state) in
      let (st, json) =
        Dashboard_http_keeper.keeper_bdi_snapshot_json config name
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with "/tool-stats" then
    let name = extract_name "/tool-stats" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let config = (Mcp_server.workspace_config state) in
      let masc_root = Workspace.masc_root_dir config in
      let window_hours =
        Server_utils.int_query_param req "window_hours"
          ~default:24
        |> max 1 |> min 168  (* 1h .. 7d *)
      in
      (* Trajectory scan + tool-stat aggregation + hourly timeline +
         coverage-gap lookup all hit disk under [masc_root]. 5-trial
         latency variance 0.16s..1.92s (mean ~1.0s) on PR #19097 HEAD
         because each miss ran on the calling fiber's Eio main domain.
         Mirrors PRs #19088 / #19097 — cache + offload, key includes the
         inputs that change the result. *)
      let cache_key =
        Printf.sprintf "keeper:tool-stats:%s:%s:%d" masc_root name window_hours
      in
      let json =
        Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
          Domain_pool_ref.submit_io_or_inline (fun () ->
            let since =
              Time_compat.now ()
              -. (float_of_int window_hours *. Masc_time_constants.hour)
            in
            let read_result =
              Trajectory.read_entries_since_result ~masc_root ~keeper_name:name ~since
            in
            let entries = read_result.Trajectory.entries in
            let tools = Trajectory.aggregate_tool_stats entries in
            let timeline = Trajectory.hourly_timeline entries in
            let latest_ts =
              List.fold_left
                (fun acc (entry : Trajectory.tool_call_entry) ->
                  match acc with
                  | Some ts when ts >= entry.ts -> acc
                  | _ -> Some entry.ts)
                None entries
            in
            let latest_age_s =
              match latest_ts with
              | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
              | None -> None
            in
            let dashboard_surface = "/api/v1/keepers/:name/tool-stats" in
            let coverage_gaps =
              Telemetry_coverage_gap.read_recent ~masc_root ~n:32
              |> List.filter (fun gap ->
                   String.equal
                     (Safe_ops.json_string ~default:"" "dashboard_surface" gap)
                     dashboard_surface
                   &&
                   match Safe_ops.json_string_opt "keeper_name" gap with
                   | Some keeper_name -> String.equal keeper_name name
                   | None -> true)
            in
            let latest_gap =
              List.rev coverage_gaps |> List.find_opt (fun _ -> true)
            in
            let health, stale_reason =
              match latest_gap with
              | Some gap ->
                  ( "coverage_gap",
                    Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
              | None -> (
                  match latest_age_s with
                  | None -> ("empty", "no_entries")
                  | Some age when age > freshness_slo_s ->
                      ("stale", "freshness_slo_exceeded")
                  | Some _ -> ("ok", ""))
            in
            `Assoc [
              ("keeper", `String name);
              ("window_hours", `Int window_hours);
              ("total_entries", `Int (List.length entries));
              ("source", `String "trajectory_tool_call");
              ( "producer",
                `String
                  "keeper_hooks_oas.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
              ("durable_store", `String (Trajectory.trajectories_dir masc_root name));
              ("dashboard_surface", `String dashboard_surface);
              ("freshness_slo_s", `Float freshness_slo_s);
              ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
              ( "latest_ts_iso",
                match latest_ts with
                | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
                | None -> `Null );
              ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
              ("health", `String health);
              ( "stale_reason",
                if stale_reason = "" then `Null else `String stale_reason );
              ( "gate_decode",
                `Assoc
                  [
                    ( "parsed_gate_count",
                      `Int read_result.Trajectory.gate_decode.parsed_gate_count );
                    ( "legacy_default_count",
                      `Int read_result.Trajectory.gate_decode.legacy_default_count );
                  ] );
              ("coverage_gaps", `List coverage_gaps);
              ("tools", `List (List.map Trajectory.tool_stat_to_json tools));
              ("timeline", `List (List.map Trajectory.hourly_bucket_to_json timeline));
            ]))
      in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/tool-calls" then
    let name = extract_name "/tool-calls" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min 200
      in
      let entries =
        Keeper_tool_call_log.read_recent ~keeper_name:name ~n:limit ()
      in
      let config = (Mcp_server.workspace_config state) in
      let masc_root = Workspace.masc_root_dir config in
      let latest_ts =
        List.fold_left
          (fun acc json ->
            match Safe_ops.json_float_opt "ts" json with
            | Some ts -> (
                match acc with
                | Some existing when existing >= ts -> acc
                | _ -> Some ts)
            | None -> acc)
          None entries
      in
      let dashboard_surface = "/api/v1/keepers/:name/tool-calls" in
      let latest_age_s =
        match latest_ts with
        | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
        | None -> None
      in
      let coverage_gaps =
        Telemetry_coverage_gap.read_recent ~masc_root ~n:32
        |> List.filter (fun gap ->
             String.equal "tool_call_io"
               (Safe_ops.json_string ~default:"" "source" gap)
             &&
             match Safe_ops.json_string_opt "keeper_name" gap with
             | Some keeper_name -> String.equal keeper_name name
             | None -> true)
      in
      let latest_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
      let health, stale_reason =
        match latest_gap with
        | Some gap ->
          ( "coverage_gap",
            Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
        | None -> (
            match latest_age_s with
            | None -> ("empty", "no_entries")
            | Some age when age > freshness_slo_s ->
                ("stale", "freshness_slo_exceeded")
            | Some _ -> ("ok", ""))
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length entries));
        ("source", `String "tool_call_io");
        ( "producer",
          `String
            "keeper_hooks_oas.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
        ("durable_store", `String (Filename.concat masc_root "tool_calls"));
        ("dashboard_surface", `String dashboard_surface);
        ("freshness_slo_s", `Float freshness_slo_s);
        ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
        ( "latest_ts_iso",
          match latest_ts with
          | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
          | None -> `Null );
        ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
        ("health", `String health);
        ( "stale_reason",
          if stale_reason = "" then `Null else `String stale_reason );
        ("coverage_gaps", `List coverage_gaps);
        ("entries", `List entries);
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/turn-records" then
    (* RFC-0233 §2.3 PR-4: serve TurnRecords with server-side
       consecutive-pair block diffs so the dashboard stays a renderer
       of the tested OCaml diff (views derive; no view-side repair). *)
    let name = extract_name "/turn-records" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min trajectory_max_limit
      in
      let config = (Mcp_server.workspace_config state) in
      let store = Keeper_types_support.keeper_turn_record_store config name in
      let raw_rows = Dated_jsonl.read_recent store limit in
      (* Strict decode: malformed rows are counted and reported, never
         repaired or silently dropped (RFC-0233 §4). *)
      let records_rev, skipped_rows =
        List.fold_left
          (fun (acc, skipped) json ->
            match Turn_record.of_json json with
            | Ok record -> (record :: acc, skipped)
            | Error _ -> (acc, skipped + 1))
          ([], 0) raw_rows
      in
      let records = List.rev records_rev in
      let block_json = Turn_record.prompt_block_to_json in
      let entries =
        Turn_record.entries_with_diffs records
        |> List.map (fun ((record : Turn_record.t), diff) ->
             let diff_vs_prev =
               match diff with
               | Some (d : Turn_record.block_diff) ->
                 `Assoc
                   [ ("added", `List (List.map block_json d.added))
                   ; ("removed", `List (List.map block_json d.removed))
                   ; ( "changed"
                     , `List
                         (List.map
                            (fun (prev_b, next_b) ->
                              `Assoc
                                [ ("prev", block_json prev_b)
                                ; ("next", block_json next_b)
                                ])
                            d.changed) )
                   ]
               | None -> `Null
             in
             `Assoc
               [ ("record", Turn_record.to_json record)
               ; ("diff_vs_prev", diff_vs_prev)
               ])
      in
      let latest_ts =
        List.fold_left
          (fun acc (r : Turn_record.t) ->
            match acc with
            | Some existing when existing >= r.ts -> acc
            | _ -> Some r.ts)
          None records
      in
      let latest_age_s =
        match latest_ts with
        | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
        | None -> None
      in
      let health, stale_reason =
        match latest_age_s with
        | None -> ("empty", "no_entries")
        | Some age when age > freshness_slo_s ->
            ("stale", "freshness_slo_exceeded")
        | Some _ -> ("ok", "")
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length records));
        ("skipped_rows", `Int skipped_rows);
        ("source", `String "turn_record");
        ("producer", `String "keeper_agent_run.run_turn|keeper_turn_record_writer");
        ( "durable_store",
          `String
            (Filename.concat
               (Workspace.masc_root_dir config)
               (Printf.sprintf "keepers/%s/turn-records" name)) );
        ("dashboard_surface", `String "/api/v1/keepers/:name/turn-records");
        ("freshness_slo_s", `Float freshness_slo_s);
        ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
        ( "latest_ts_iso",
          match latest_ts with
          | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
          | None -> `Null );
        ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
        ("health", `String health);
        ( "stale_reason",
          if stale_reason = "" then `Null else `String stale_reason );
        ("entries", `List entries);
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/trajectory" then
    let name = extract_name "/trajectory" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let config = (Mcp_server.workspace_config state) in
      (match Keeper_meta_store.read_meta config name with
       | Error e ->
         respond_error ~status:`Internal_server_error reqd e
       | Ok None ->
         respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
       | Ok (Some m) ->
         let trajectory_default_limit = 50 in
         let trace_id =
           Keeper_id.Trace_id.to_string m.runtime.trace_id
         in
         let limit =
           Server_utils.int_query_param req "limit"
             ~default:trajectory_default_limit
           |> max 1 |> min trajectory_max_limit
         in
         (* Allow caller to request more result text up to a safe max.
            Default 2000 chars is enough for the collapsed list view;
            set result_max_len=10000 (or higher, capped at 10000) to
            get full detail for an expanded entry. *)
         let result_max_len =
           Server_utils.int_query_param req "result_max_len"
             ~default:2000
           |> max 0 |> min 10000
         in
         let content_max_len =
           Server_utils.int_query_param req "content_max_len"
             ~default:Trajectory.default_thinking_truncation
           |> max 0 |> min 50000
         in
         let include_thinking =
           Server_utils.bool_query_param req "include_thinking"
             ~default:false
         in
         let masc_root = Workspace.masc_root_dir config in
         let trajectory_lines =
           Trajectory.read_all_lines ~masc_root ~keeper_name:m.name
             ~trace_id
         in
         let all_lines =
           if include_thinking then
             merge_keeper_trace_lines ~config ~trace_id trajectory_lines
           else
             trajectory_lines
         in
         (* Filter out thinking entries if not requested *)
         let lines =
           if include_thinking then all_lines
           else List.filter (function
             | Trajectory.Tool_call _ -> true
             | Trajectory.Thinking _ -> false) all_lines
         in
         let total = List.length lines in
         let recent =
           if total <= limit then lines
           else
             let drop = total - limit in
             List.filteri (fun i _e -> i >= drop) lines
         in
         let json = `Assoc [
           ("keeper", `String name);
           ("trace_id", `String trace_id);
           ("generation", `Int m.runtime.generation);
           ("total_entries", `Int total);
           ("showing", `Int (List.length recent));
           ("entries", `List (List.map
             (Trajectory.trajectory_line_to_json ~result_max_len ~content_max_len) recent));
         ] in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  else if ends_with "/transitions" then
    let name = extract_name "/transitions" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
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
      Http.Response.json_value ~compress:true ~request:req json reqd
  (* #12798 Dashboard Gaps: lifecycle event timeline per keeper. *)
  else if ends_with "/lifecycle" then
    let name = extract_name "/lifecycle" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
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
  else if ends_with "/eval" then
    let name = extract_name "/eval" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      let limit =
        Server_utils.int_query_param req "limit" ~default:10
        |> max 1 |> min 100
      in
      (* Use keeper name as agent_name for eval lookup.
         Keepers may also have a separate agent_name — look up both. *)
      let config = (Mcp_server.workspace_config state) in
      let agent_name_opt =
        match Keeper_meta_store.read_meta config name with
        | Ok (Some m) when m.agent_name <> name -> Some m.agent_name
        | _ -> None
      in
      let snapshots_by_name =
        Dashboard_eval_feed.read_latest ~base_path ~agent_name:name ~limit
      in
      let snapshots =
        match agent_name_opt with
        | Some agent_name when snapshots_by_name = [] ->
            Dashboard_eval_feed.read_latest ~base_path ~agent_name ~limit
        | _ -> snapshots_by_name
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
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/state-diagram" then
    let name = extract_name "/state-diagram" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      let phase = Keeper_registry.get_phase ~base_path name in
      let current = match phase with Some p -> p | None -> Keeper_state_machine.Offline in
      let mermaid = Keeper_state_machine_mermaid.phase_to_mermaid ~current in
      let phase_str = Keeper_state_machine.phase_to_string current in
      let stats = Thompson_sampling.get_stats name in
      let meta = Keeper_meta_store.read_meta
          (Mcp_server.workspace_config state) name in
      let turn_outcome : [`Ok | `Failed] option =
        match Keeper_registry.get ~base_path:(Mcp_server.workspace_config state).base_path name with
        | Some entry when entry.turn_consecutive_failures > 0 ->
          Some `Failed
        | Some _ -> Some `Ok
        | None -> None
      in
      let decision_pipeline_mermaid =
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ?turn_outcome
          ~guard_penalty_total:stats.guard_penalties_total
          ~phase:current
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ()
      in
      let runtime_fsm_mermaid =
        match meta with
        | Ok (Some m) ->
          let models = [ "candidate" ] in
          let provider_health = [] in
          Keeper_decision_audit.runtime_fsm_to_mermaid
            ~provider_health
            ~effective_runtime_reason:"runtime"
            ~models ~last_provider_result:None ()
        | _ ->
          Keeper_decision_audit.runtime_fsm_to_mermaid
            ~models:[] ~last_provider_result:None ()
      in
      let runtime_models = [] in
      let last_provider = `Null in
      (* Memory tier usage: join kind_caps (policy) with kind_counts (bank
         summary). Each kind reports used / cap so the dashboard tier
         panel can render saturation without re-reading the memory file.

         RFC-0149 §3.1: route the bank read through the typed Result
         resolver.  [memory_kind_usage] keeps its [`List …] shape for
         existing dashboard consumers
         (dashboard/src/components/keeper-memory-tier-panel.ts,
         dashboard/src/components/ide/ide-persistence-panel.ts).  The
         typed [Keeper_memory_recall_exn_class.t] label rides on the
         sibling [memory_kind_usage_error_class] field so an IO fault is
         distinguishable from "memory bank empty / no kinds recorded".  *)
      let used_by_kind, memory_kind_usage_error_class =
        match meta with
        | Ok (Some _) ->
          (match
             Keeper_memory.read_keeper_memory_summary_result
               (Mcp_server.workspace_config state)
               ~name ~max_bytes:120_000 ~max_lines:200 ~recent_limit:0
           with
           | Ok summary ->
             summary.Keeper_memory.kind_counts, None
           | Error exn_class ->
             [], Some (Keeper_memory_recall_exn_class.to_label exn_class))
        | _ -> [], None
      in
      let memory_kind_usage : Yojson.Safe.t =
        let caps = Keeper_memory_policy.kind_caps () in
        let lookup_used k =
          List.assoc_opt k used_by_kind |> Option.value ~default:0
        in
        `List (List.map (fun (kind, cap) ->
          `Assoc [
            "kind", `String kind;
            "used", `Int (lookup_used kind);
            "cap", `Int cap;
            "priority", `Int (Keeper_memory_policy.priority_for_kind ~kind);
          ]) caps)
      in
      let memory_kind_usage_error_class_json : Yojson.Safe.t =
        Json_util.string_opt_to_json memory_kind_usage_error_class
      in
      (* Compaction sub-FSM: only emit a diagram when the keeper is in
         the [Compacting] phase. The three nodes mirror
         [specs/bug-models/MemoryCompaction.tla]. *)
      let compaction_submachine_mermaid =
        match current with
        | Keeper_state_machine.Compacting ->
          let b = Buffer.create 256 in
          Buffer.add_string b "stateDiagram-v2\n";
          Buffer.add_string b "    [*] --> Accumulating\n";
          Buffer.add_string b "    Accumulating --> Compacting: ratio_gate\n";
          Buffer.add_string b "    Compacting --> Done: Compaction_completed\n";
          Buffer.add_string b "    Compacting --> Accumulating: Compaction_failed\n";
          Buffer.add_string b "    Done --> [*]\n";
          Buffer.add_string b
            "    classDef active fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
          Buffer.add_string b "    class Compacting active\n";
          `String (Buffer.contents b)
        | _ -> `Null
      in
      let json = `Assoc [
        "keeper", `String name;
        "current_phase", `String phase_str;
        "mermaid", `String mermaid;
        "decision_pipeline_mermaid", `String decision_pipeline_mermaid;
        "runtime_fsm_mermaid", `String runtime_fsm_mermaid;
        "compaction_submachine_mermaid", compaction_submachine_mermaid;
        "thompson_alpha", `Float stats.alpha;
        "thompson_beta", `Float stats.beta;
        "runtime_models", `List (List.map (fun s -> `String s) runtime_models);
        "last_provider_result", last_provider;
        "memory_kind_usage", memory_kind_usage;
        "memory_kind_usage_error_class", memory_kind_usage_error_class_json;
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if req_path = prefix ^ "composite" then
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
  else if ends_with "/composite" then
    (* RFC-0003 §7: composite lifecycle snapshot derived from the
       registry entry via the [Keeper_composite_observer] pure
       projection. No mutation, no I/O, no provider/token access. *)
    let name = extract_name "/composite" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match Keeper_registry.get ~base_path name with
       | None ->
         respond_error ~status:`Not_found reqd
           (Printf.sprintf "keeper %S not registered" name)
       | Some entry ->
         let json =
           Server_dashboard_http.dashboard_keeper_composite_json
             ~config:(Mcp_server.workspace_config state) entry
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  else if req_path = prefix ^ "regime" then
    (* 7th FSM axis MVP: fleet-wide behavioral-regime snapshot. Same
       purity contract as the composite route above, uses the
       [Keeper_behavioral_regime_observer] pure projection. *)
    let base_path = (Mcp_server.workspace_config state).base_path in
    let snapshots =
      Keeper_behavioral_regime_observer.all_snapshots ~base_path ()
    in
    let json =
      `Assoc [
        "generated_at", `String (Masc_domain.now_iso ());
        "count", `Int (List.length snapshots);
        "snapshots",
          `List
            (List.map
               Keeper_behavioral_regime_observer.snapshot_to_json
               snapshots);
      ]
    in
    Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/regime" then
    (* Per-keeper behavioral-regime snapshot. *)
    let name = extract_name "/regime" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match Keeper_registry.get ~base_path name with
       | None ->
         respond_error ~status:`Not_found reqd
           (Printf.sprintf "keeper %S not registered" name)
       | Some entry ->
         let snapshot =
           Keeper_behavioral_regime_observer.observe entry
         in
         let json =
           Keeper_behavioral_regime_observer.snapshot_to_json snapshot
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  else
    respond_error ~status:`Not_found reqd "not found"
