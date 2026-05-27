(** Keeper HTTP API handlers — POST handlers + GET sub-routes.

    POST handlers extracted to [Server_dashboard_http_keeper_api_post]
    (godfile decomp). *)

include Server_dashboard_http_keeper_api_post

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
      let base_dir = state.Mcp_server.room_config.base_path in
      let messages =
        Keeper_chat_store.load ~base_dir ~keeper_name:name
      in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (Keeper_chat_store.to_json_array messages)
  else if ends_with keeper_suffix_checkpoints then
    let name = extract_name keeper_suffix_checkpoints in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let (st, json) = keeper_checkpoint_inventory_json state.Mcp_server.room_config name in
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
        |> max 1 |> min 500
      in
      let st, json =
        keeper_runtime_trace_json state.Mcp_server.room_config name
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
      let config = state.Mcp_server.room_config in
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
      let config = state.Mcp_server.room_config in
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
      let config = state.Mcp_server.room_config in
      let masc_root = Coord.masc_root_dir config in
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
        Dashboard_cache.get_or_compute cache_key ~ttl:5.0 (fun () ->
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
            let freshness_slo_s = 300.0 in
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
              ( "latest_ts_unix",
                match latest_ts with Some ts -> `Float ts | None -> `Null );
              ( "latest_ts_iso",
                match latest_ts with
                | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
                | None -> `Null );
              ( "latest_age_s",
                match latest_age_s with Some age -> `Float age | None -> `Null );
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
      let config = state.Mcp_server.room_config in
      let masc_root = Coord.masc_root_dir config in
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
      let freshness_slo_s = 300.0 in
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
        ( "latest_ts_unix",
          match latest_ts with Some ts -> `Float ts | None -> `Null );
        ( "latest_ts_iso",
          match latest_ts with
          | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
          | None -> `Null );
        ( "latest_age_s",
          match latest_age_s with Some age -> `Float age | None -> `Null );
        ("health", `String health);
        ( "stale_reason",
          if stale_reason = "" then `Null else `String stale_reason );
        ("coverage_gaps", `List coverage_gaps);
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
      let config = state.Mcp_server.room_config in
      (match Keeper_types.read_meta config name with
       | Error e ->
         respond_error ~status:`Internal_server_error reqd e
       | Ok None ->
         respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
       | Ok (Some m) ->
         let trajectory_default_limit = 50 in
         let trajectory_max_limit = 500 in
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
         let masc_root = Coord.masc_root_dir config in
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
      let base_path = state.Mcp_server.room_config.base_path in
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
      let base_path = state.Mcp_server.room_config.base_path in
      let limit =
        Server_utils.int_query_param req "limit" ~default:10
        |> max 1 |> min 100
      in
      (* Use keeper name as agent_name for eval lookup.
         Keepers may also have a separate agent_name — look up both. *)
      let config = state.Mcp_server.room_config in
      let agent_name_opt =
        match Keeper_types.read_meta config name with
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
      let base_path = state.Mcp_server.room_config.base_path in
      let phase = Keeper_registry.get_phase ~base_path name in
      let current = match phase with Some p -> p | None -> Keeper_state_machine.Offline in
      let mermaid = Keeper_state_machine_mermaid.phase_to_mermaid ~current in
      let phase_str = Keeper_state_machine.phase_to_string current in
      let stats = Thompson_sampling.get_stats name in
      let meta = Keeper_types.read_meta
          state.Mcp_server.room_config name in
      let tool_count = match meta with
        | Ok (Some m) ->
          List.length (Agent_tool_dispatch_runtime.keeper_allowed_tool_names m)
        | _ -> 0
      in
      let recovery_floor_count =
        List.length (Keeper_tool_policy.failing_minimum_tool_names ())
      in
      let turn_outcome : [`Ok | `Failed] option =
        match Keeper_registry.get ~base_path:state.Mcp_server.room_config.base_path name with
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
          ~tool_count
          ~recovery_floor_count
          ()
      in
      let cascade_fsm_mermaid =
        match meta with
        | Ok (Some m) ->
          let routing =
            Keeper_cascade_routing.select_cascade
              ~base_cascade:(Keeper_types.cascade_name_of_meta m) ~phase:current
          in
          let models = [ "candidate" ] in
          let provider_health = [] in
          (* Slot occupancy from the local runtime pool. The cascade FSM
             shares these slots across all keepers, so rendering the
             fleet-global (used, capacity) is the honest value — a
             per-cascade split would claim an isolation the runtime does
             not actually provide. *)
          let slot_state =
            let used = Local_runtime_pool.allocated_slots () in
            let max = Local_runtime_pool.configured_capacity () in
            if max > 0 then Some (used, max) else None
          in
          Keeper_decision_audit.cascade_fsm_to_mermaid
            ~provider_health
            ?slot_state
            ~effective_cascade_reason:routing.reason
            ~models ~last_provider_result:None ()
        | _ ->
          Keeper_decision_audit.cascade_fsm_to_mermaid
            ~models:[] ~last_provider_result:None ()
      in
      let cascade_models = [] in
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
               state.Mcp_server.room_config
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
        match memory_kind_usage_error_class with
        | Some label -> `String label
        | None -> `Null
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
        "cascade_fsm_mermaid", `String cascade_fsm_mermaid;
        "compaction_submachine_mermaid", compaction_submachine_mermaid;
        "thompson_alpha", `Float stats.alpha;
        "thompson_beta", `Float stats.beta;
        "tool_count", `Int tool_count;
        "recovery_floor_count", `Int recovery_floor_count;
        "cascade_models", `List (List.map (fun s -> `String s) cascade_models);
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
        ~config:state.Mcp_server.room_config ()
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
      let base_path = state.Mcp_server.room_config.base_path in
      (match Keeper_registry.get ~base_path name with
       | None ->
         respond_error ~status:`Not_found reqd
           (Printf.sprintf "keeper %S not registered" name)
       | Some entry ->
         let json =
           Server_dashboard_http.dashboard_keeper_composite_json
             ~config:state.Mcp_server.room_config entry
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  else if req_path = prefix ^ "regime" then
    (* 7th FSM axis MVP: fleet-wide behavioral-regime snapshot. Same
       purity contract as the composite route above, uses the
       [Keeper_behavioral_regime_observer] pure projection. *)
    let base_path = state.Mcp_server.room_config.base_path in
    let snapshots =
      Keeper_behavioral_regime_observer.all_snapshots ~base_path ()
    in
    let json =
      `Assoc [
        "generated_at", `Float (Unix.gettimeofday ());
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
      let base_path = state.Mcp_server.room_config.base_path in
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
