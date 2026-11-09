(* See server_dashboard_http_keeper_tool_calls.mli. *)

module Http = Http_server_eio

let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let freshness_slo_s = Server_dashboard_http_core_cache.freshness_slo_s

let tool_call_entries ~keeper_name ~limit =
  Result.map
    (List.map Keeper_tool_definition_source.annotate_row)
    (Keeper_tool_call_log.read_recent ~keeper_name ~n:limit ())
;;

let keeper_tool_call_lookup_response ~config ~keeper_name req =
  let query = Uri.query (Uri.of_string req.Httpun.Request.target) in
  let execution_parameters =
    List.filter (fun (name, _) -> String.equal name "execution_id") query
  in
  let batch_parameters =
    List.filter (fun (name, _) -> String.equal name "execution_ids") query
  in
  let error status code detail =
    Some
      (status, `Assoc [ "error", `String detail; "code", `String code ])
  in
  let lookup execution_ids =
    let store = Dated_jsonl.open_store
        (Dated_jsonl.Store.at (Workspace.dated_store_root config)
           Dated_jsonl.Store.Root.Tool_calls) in
    Keeper_tool_call_index.by_execution_ids ~store ~keeper_name ~execution_ids
  in
  let single () = match execution_parameters with
  | [] -> None
  | [ _, [ execution_id ] ] when String.trim execution_id <> "" ->
    if not (Keeper_config.validate_name keeper_name) then
      error `Bad_request "invalid_keeper_name" "invalid keeper name"
    else
      (match lookup [ execution_id ] with
       | Error detail -> error `Service_unavailable "tool_call_store_unavailable" detail
       | Ok [] ->
         error `Not_found "tool_call_not_found"
           "No tool call with this execution ID exists for this keeper"
       | Ok [ row ] ->
         Some
           (`OK,
            `Assoc
              [ "keeper", `String keeper_name
              ; "execution_id", `String execution_id
              ; "entry", Keeper_tool_definition_source.annotate_row row
              ])
       | Ok (_ :: _ :: _) ->
         error `Conflict "tool_call_ambiguous"
           "Multiple authoritative tool calls share this execution ID")
  | _ ->
    error `Bad_request "invalid_execution_id"
      "execution_id must occur exactly once with a non-blank value"
  in
  match batch_parameters, execution_parameters with
  | [], _ -> single ()
  | _ :: _, _ :: _ ->
    error `Bad_request "invalid_execution_query"
      "execution_id and execution_ids cannot be combined"
  | [ _, [ encoded ] ], [] ->
    let module Id_set = Set.Make (String) in
    let rec decode seen kept = function
      | [] -> Some (List.rev kept)
      | `String id :: rest
        when String.trim id <> "" && not (Id_set.mem id seen) ->
        decode (Id_set.add id seen) (id :: kept) rest
      | _ :: _ -> None
    in
    let ids =
      match Yojson.Safe.from_string encoded with
      | `List rows -> decode Id_set.empty [] rows
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> None
      | exception Yojson.Json_error _ -> None
    in
    (match ids with
     | None -> error `Bad_request "invalid_execution_ids"
         "execution_ids must be a JSON array of distinct non-blank strings"
     | Some _ when not (Keeper_config.validate_name keeper_name) ->
       error `Bad_request "invalid_keeper_name" "invalid keeper name"
     | Some execution_ids ->
       (match lookup execution_ids with
        | Error detail -> error `Service_unavailable "tool_call_store_unavailable" detail
        | Ok rows ->
          Some (`OK, `Assoc
            [ "keeper", `String keeper_name
            ; "requested_execution_ids", `List (List.map (fun id -> `String id) execution_ids)
            ; "entries", `List (List.map Keeper_tool_definition_source.annotate_row rows)
            ])))
  | (_ :: _ :: _ | [ _, ([] | _ :: _ :: _) ]), [] ->
    error `Bad_request "invalid_execution_ids"
      "execution_ids must occur exactly once with one JSON array"
;;

(* An index the reader cannot open is answered as the same 503 the exact
   execution lookup above gives for unavailable storage, not as an empty
   entry list: [count: 0] was indistinguishable from a keeper that made no
   calls (audit F397). *)
let tool_call_store_unavailable_json ~keeper_name detail =
  `Assoc
    [ "keeper", `String keeper_name
    ; "error", `String detail
    ; "code", `String "tool_call_store_unavailable"
    ]
;;

(* Maximum per-keeper entries for /tool-calls. *)
let tool_calls_limit_max = 200

let handle_stats_get state req reqd name =
  if not (Keeper_config.validate_name name) then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
      reqd
  else
    let config = (Mcp_server.workspace_config state) in
    let masc_root = Workspace.masc_dir config in
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
    let payload =
      Dashboard_cache.get_or_compute_payload cache_key ~ttl:standard_cache_ttl_s (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
        let since =
          Time_compat.now ()
          -. (float_of_int window_hours *. Masc_time_constants.hour)
        in
        let entries =
          Trajectory.read_entries_since ~masc_root ~keeper_name:name ~since
        in
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
          Keeper_status_runtime.keeper_tool_call_source_health
            ~gap:
              (Option.map
                 (fun gap ->
                    ( Safe_ops.json_float_opt "ts" gap,
                      Safe_ops.json_string ~default:"coverage_gap"
                        "stale_reason" gap ))
                 latest_gap)
            ~latest_ts ~latest_age_s ~freshness_slo_s
        in
        `Assoc [
          ("keeper", `String name);
          ("window_hours", `Int window_hours);
          ("total_entries", `Int (List.length entries));
          ("source", `String "trajectory_tool_call");
          ( "producer",
            `String
              "keeper_hooks_agent_core.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
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
          ("coverage_gaps", `List coverage_gaps);
          ("tools", `List (List.map Trajectory.tool_stat_to_json tools));
          ("timeline", `List (List.map Trajectory.hourly_bucket_to_json timeline));
        ]))
    in
    Server_cached_read_http.respond ~request:req reqd payload
;;

let handle_result_get state req reqd keeper =
  let status,json = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    Server_keeper_tool_result.response ~config:(Mcp_server.workspace_config state) ~keeper req) in
  Http.Response.json_value ~status:(status :> Httpun.Status.t)
    ~compress:true ~request:req json reqd
;;

let handle_calls_get state req reqd name =
  if not (Keeper_config.validate_name name) then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
      reqd
  else
    match
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        keeper_tool_call_lookup_response
          ~config:(Mcp_server.workspace_config state) ~keeper_name:name req)
    with
    | Some (status, json) ->
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
    | None ->
    let limit =
      Server_utils.int_query_param req "limit" ~default:50
      |> max 1 |> min tool_calls_limit_max
    in
    let config = (Mcp_server.workspace_config state) in
    let masc_root = Workspace.masc_dir config in
    (* The durable index selects this Keeper before limiting rows. A fleet
       tail cannot bound the requested Keeper's history when others are busy.
       Keep ledger/index I/O off the request domain and preserve chronological
       order and row annotation from the existing response contract. *)
    let status, json =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            match tool_call_entries ~keeper_name:name ~limit with
            | Error (Keeper_tool_call_log.Index_unavailable detail) ->
              `Service_unavailable,
              tool_call_store_unavailable_json ~keeper_name:name detail
            | Ok entries ->
            let latest_ts =
              List.fold_left
                (fun acc json ->
                  match Safe_ops.json_float_opt "ts" json with
                  | Some ts -> (
                      match acc with
                      | Some existing when existing >= ts -> acc
                      | Some _ | None -> Some ts)
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
            let latest_gap =
              List.rev coverage_gaps |> List.find_opt (fun _ -> true)
            in
            let health, stale_reason =
              Keeper_status_runtime.keeper_tool_call_source_health
                ~gap:
                  (Option.map
                     (fun gap ->
                        ( Safe_ops.json_float_opt "ts" gap,
                          Safe_ops.json_string ~default:"coverage_gap"
                            "stale_reason" gap ))
                     latest_gap)
                ~latest_ts ~latest_age_s ~freshness_slo_s
            in
            `OK,
            `Assoc [
              ("keeper", `String name);
              ("count", `Int (List.length entries));
              ("source", `String "tool_call_io");
              ( "producer",
                `String
                  "keeper_hooks_agent_core.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
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
            ])
    in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd
;;
