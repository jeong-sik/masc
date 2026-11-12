
open Server_utils

module Http = Http_server_eio

module Cache = Server_dashboard_json_cache

let dashboard_cost_latency_cache = Cache.create ()
let dashboard_keeper_practice_cache = Cache.create ()

let cache_key parts = String.concat "\x1f" parts

(* Declarations remain separate from the catalog limit and effective context.
   Official clients do not expose an original capability catalog here. *)
let runtime_specification_json (runtime : Runtime_instance.t) =
  let catalog = match runtime.execution with
    | Runtime_execution.Agent_core sealed ->
      Llm_provider.Provider_config.capabilities_for_config_model
        { (Runtime_account_access.api_declaration sealed) with model_capabilities_override = None }
    | Runtime_execution.Codex_app_server _ | Runtime_execution.Claude_code _
    | Runtime_execution.Antigravity_cli _ | Runtime_execution.Muse_serve _
    | Runtime_execution.Vibe_cli _ -> None in
  `Assoc [ "runtime_id", `String runtime.id;
    "catalog_context", Json_util.int_opt_to_json
      (Option.bind catalog (fun caps -> caps.Llm_provider.Capabilities.max_context_tokens));
    "catalog_max_output", Json_util.int_opt_to_json
      (Option.bind catalog (fun caps -> caps.Llm_provider.Capabilities.max_output_tokens));
    "model_context", Json_util.int_opt_to_json runtime.model.max_context;
    "provider_context", Json_util.int_opt_to_json runtime.provider.max_context;
    "binding_context", Json_util.int_opt_to_json runtime.binding.max_context ]

let empty_cost_latency_json ~window =
  `Assoc
    [ "perAgent", `List []
    ; ( "matrix"
      , `Assoc [ "providers", `List []; "models", `List []; "grid", `List [] ] )
    ; "latencyBuckets", `List []
    ; "p50", `Null
    ; "p95", `Null
    ; "total_cost_usd", `Float 0.0
    ; "window_minutes", `Int window
    ; "cost_ledger_read", `Assoc [ "state", `String "pending" ]
    ; "generated_at", `Float (Unix.gettimeofday ())
    ]

let dashboard_feed_limit req =
  int_query_param req "limit" ~default:200 |> clamp ~min_v:1 ~max_v:200

let add_routes ~sw router =
  router
  |> Server_route.get Server_route.Public_read "/api/v1/providers" (fun _state req reqd ->
         let json = Server_dashboard_http_runtime_info.runtime_inventory_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/models/metrics" (fun state req reqd ->
         match Server_model_metrics_stream.request req with
         | Error detail -> Http.Response.json_value ~status:`Bad_request
             (`Assoc ["error", `String detail]) reqd
         | Ok request ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let _, result = Pool_work.submit (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
           Server_model_metrics_stream.read_snapshot ~base_path ~request ~now:(Time_compat.now ())
             Model_inference_metrics_kept.empty)) in
         match result with
         | Ok snapshot -> Http.Response.json_value ~compress:true ~request:req snapshot.json reqd
         | Error detail -> Http.Response.json_value ~status:`Service_unavailable ~request:req
             (`Assoc ["error", `String detail]) reqd
       )
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/metrics" (fun state _agent req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         (* The history keeps each file's rows between reads, so a read after
            a runtime_metrics push reads only the rows written since; the first
            read of a file reads it whole, on a worker. *)
         match
           Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
             (* NDT-OK: request-time clock for a trailing window read. *)
             Server_runtime_metrics.read ~base_path ~now:(Unix.gettimeofday ()))
         with
         | history ->
           let _, _, runtimes = Runtime.get_default_route_and_runtimes () in
           let json = `Assoc [ "history", history;
             "specifications", `List (List.map runtime_specification_json runtimes) ] in
           Http.Response.json_value ~compress:true ~request:req json reqd
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
           Log.Server.warn "runtime history read failed: %s" (Printexc.to_string exn);
           Http.Response.json_value ~status:`Service_unavailable ~request:req
             (`Assoc [ "error", `String "runtime history unavailable" ]) reqd)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/keeper-costs" (fun state req reqd ->
         match
           Dashboard_http_keeper_feeds.keeper_costs_window_of_query
             (query_param req "window")
         with
         | Error message ->
             Http.Response.json_value ~status:`Bad_request ~request:req
               (`Assoc [ ("ok", `Bool false); ("error", `String message) ])
               reqd
         | Ok window ->
         let config = (Mcp_server.workspace_config state) in
         (* The window keeps each Keeper's metrics day files between reads, so
            a read after a keeper_costs push folds only the rows written since
            and answers them; the first read of a file reads it whole, on a
            worker. *)
         let json =
           Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
               let keeper_names =
                 (match Keeper_meta_store.keeper_names_result config with
                  | Ok names -> names
                  | Error detail ->
                    Log.Keeper.warn "dashboard keeper feed: keeper names unread: %s" detail;
                    [])
               in
               (* Only Keepers whose meta reads have a row. A Keeper whose meta
                  is there but does not read is reported once, by the operator
                  snapshot's [keepers_unread], which the briefing carries; a
                  reader that asks this answer for it finds no row and draws it
                  unknown. *)
               let keepers =
                 List.filter_map
                   (fun name ->
                     match Keeper_meta_store.read_meta_presence config name with
                     | Ok (Keeper_meta_store.Meta_present m) -> Some m
                     | Ok Keeper_meta_store.Meta_absent
                     | Ok (Keeper_meta_store.Meta_not_current _)
                     | Error _ -> None)
                   keeper_names
               in
               (* NDT-OK: request-time clock for a cost window; a dashboard read endpoint, not durable output. *)
               Dashboard_http_keeper.keeper_cost_aggregates_json ~config
                 ~keepers ~window_minutes:window ~now_ts:(Unix.gettimeofday ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/provider-usage-history" (fun state req reqd ->
         (* The window is parsed here, once; [read] takes the variant and has
            no count of its own to check. *)
         let window =
           match query_param req "days" with
           | None -> Some Server_provider_usage_history.Fourteen_days
           | Some raw ->
               Option.bind (int_of_string_opt raw)
                 Server_provider_usage_history.window_of_days
         in
         let status, json =
           match window with
           | Some window ->
               let config = Mcp_server.workspace_config state in
               (* The history keeps its day files' folds between reads, so a
                  read after a usage report folds only what the journal gained
                  and answers it; the first read of a file reads it whole, on
                  a worker. *)
               let result =
                 try
                   Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
                     (* NDT-OK: request-time clock for a read-only history window. *)
                     Server_provider_usage_history.read config ~now:(Unix.gettimeofday ())
                       ~window)
                 with
                 | Eio.Cancel.Cancelled _ as exn -> raise exn
                 | exn ->
                     Log.Server.warn "provider usage history crashed: %s"
                       (Printexc.to_string exn);
                     Error "provider usage history store unavailable"
               in
               (match result with
                | Ok json -> `OK, json
                | Error detail ->
                    `OK, `Assoc [ "state", `String "unavailable"; "reason", `String detail ])
           | None ->
               `Bad_request,
               `Assoc [ "ok", `Bool false
                      ; "error", `String "days must be 1, 7, or 14" ]
         in
         Http.Response.json_value ~status ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/cost-latency" (fun state req reqd ->
         let window = int_query_param req "window" ~default:1440 in
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json =
           Cache.read_result ~now:Unix.gettimeofday ~sw ~sync_first:false
             ~cache:dashboard_cost_latency_cache
             ~key:(cache_key [ base_path; string_of_int window ])
             ~placeholder:(empty_cost_latency_json ~window)
             ~compute:(fun () ->
               Model_inference_metrics.compute_cost_latency_json
                 ~base_path ~window_minutes:window
               |> Result.map_error Model_inference_metrics.read_error_to_string)
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/keeper-decisions" (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = Mcp_server.workspace_config state in
         match Server_dashboard_keeper_decisions_http.read_current ~config ~limit with
         | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd
         | Error error ->
             Log.Server.warn "%s" (Server_dashboard_keeper_decisions_http.read_error_to_string error);
             Http.Response.json_value ~status:`Service_unavailable ~request:req
               (Server_dashboard_keeper_decisions_http.read_error_to_json error) reqd
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
             Log.Server.warn "Keeper Decisions read failed: %s" (Printexc.to_string exn);
             Http.Response.json_value ~status:`Service_unavailable ~request:req
               (`Assoc ["error", `String "keeper_decisions_unavailable"]) reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/keeper-practice" (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = (Mcp_server.workspace_config state) in
         let key = cache_key [ config.base_path; string_of_int limit ] in
         let json =
           Cache.read ~sw ~sync_first:true
             ~cache:dashboard_keeper_practice_cache ~key
             ~placeholder:
               (Dashboard_http_keeper_practice.fleet_json ~config
                  ~keepers:[] ~limit ())
             ~compute:(fun () ->
               let keeper_names =
                 (match Keeper_meta_store.keeper_names_result config with
                  | Ok names -> names
                  | Error detail ->
                    Log.Keeper.warn "dashboard keeper practice: keeper names unread: %s" detail;
                    [])
               in
               let keepers =
                 List.filter_map (fun name ->
                   match Keeper_meta_store.read_meta config name with
                   | Ok (Some m) -> Some m
                   | Ok (None) | Error _ -> None
                 ) keeper_names
               in
               Dashboard_http_keeper_practice.fleet_json ~config ~keepers
                 ~limit ())
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
