
open Server_utils

module Http = Http_server_eio

module Cache_state = Server_dashboard_json_cache_state

type dashboard_json_cache_entry = Cache_state.t

let dashboard_metrics_cache_ttl_s = 60.0

(* Per-cache entry ceiling. The [window]/[bucket_min] query params are folded
   into the cache key unclamped (see [add_routes]), and these endpoints are
   public reads, so distinct client-supplied values would otherwise grow each
   table without bound (memory-exhaustion vector). The legitimate dashboard
   uses a small fixed set of windows, so this ceiling is never reached in
   normal operation; past it, the least-recently-refreshed entry is evicted. *)
let dashboard_metrics_cache_max_entries = 128
let dashboard_metrics_cache_mu = Stdlib.Mutex.create ()
let dashboard_model_metrics_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_runtime_metrics_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_cost_latency_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_costs_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_provider_history_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_decisions_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_decisions_log_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_practice_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8

let cache_key parts = String.concat "\x1f" parts

(* Declarations remain separate from the catalog limit and effective context.
   Official clients do not expose an original capability catalog here. *)
let runtime_specification_json (runtime : Runtime_instance.t) =
  let catalog = match runtime.execution with
    | Runtime_execution.Agent_core config ->
      Llm_provider.Provider_config.capabilities_for_config_model
        { config with model_capabilities_override = None }
    | Runtime_execution.Codex_app_server _ | Runtime_execution.Claude_code _
    | Runtime_execution.Antigravity_cli _ | Runtime_execution.Muse_serve _ -> None in
  `Assoc [ "runtime_id", `String runtime.id;
    "catalog_context", Json_util.int_opt_to_json
      (Option.bind catalog (fun caps -> caps.Llm_provider.Capabilities.max_context_tokens));
    "catalog_max_output", Json_util.int_opt_to_json
      (Option.bind catalog (fun caps -> caps.Llm_provider.Capabilities.max_output_tokens));
    "model_context", Json_util.int_opt_to_json runtime.model.max_context;
    "provider_context", Json_util.int_opt_to_json runtime.provider.max_context;
    "binding_context", Json_util.int_opt_to_json runtime.binding.max_context ]

let cache_metadata ~state ~generated_at ?age_s ?error () =
  let optional_float name = function
    | None -> []
    | Some value -> [ name, `Float value ]
  in
  let optional_string name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  `Assoc
    ([ "state", `String (Dashboard_cache_wire.to_string state)
     ; "generated_at", `Float generated_at
     ]
     @ optional_float "age_s" age_s
     @ optional_string "last_error" error)

let json_with_cache_metadata json metadata =
  match json with
  | `Assoc fields -> `Assoc (fields @ [ "cache", metadata ])
  | other -> `Assoc [ "payload", other; "cache", metadata ]

let redact_provider_history_cache_error = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "cache", `Assoc metadata ->
                 "cache", `Assoc
                   (List.map
                      (function
                        | "last_error", _ ->
                            "last_error", `String "history refresh failed"
                        | field -> field)
                      metadata)
             | field -> field)
           fields)
  | json -> json

let cache_response ~now ~placeholder = function
  | Cache_state.Fresh { json; age_s } ->
      json_with_cache_metadata json
        (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
           ~generated_at:now ~age_s ())
  | Cache_state.Stale { json; age_s; last_error } ->
      json_with_cache_metadata json
        (cache_metadata ~state:Dashboard_cache_wire.Cache_stale_refreshing
           ~generated_at:now ~age_s ?error:last_error ())
  | Cache_state.Warming { last_error } ->
      json_with_cache_metadata placeholder
        (cache_metadata ~state:Dashboard_cache_wire.Cache_warming
           ~generated_at:now ?error:last_error ())

let cached_dashboard_json_result ~now:clock ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  Eio.Switch.check sw;
  let now = clock () in
  let release owner =
    Stdlib.Mutex.protect dashboard_metrics_cache_mu (fun () ->
        match Hashtbl.find_opt cache key with
        | None -> ()
        | Some entry ->
            Option.iter (Hashtbl.replace cache key) (Cache_state.cancel ~owner entry))
  in
  let run_compute_and_store ~background owner =
    (* Cleanup is synchronous: it cannot mask cancellation with an Eio effect.
       Successful settlement has already removed this exact owner. *)
    Fun.protect ~finally:(fun () -> release owner) (fun () ->
      let run () =
        Eio.Switch.check sw;
        let result =
          (* These computes transitively take process-shared Eio mutexes.
             Executor workers carry an Eio context; a bare systhread does not.
             Keep the executor's worker-cancellation/join protocol intact. *)
          try Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ compute with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        let refreshed_at = clock () in
        Stdlib.Mutex.protect dashboard_metrics_cache_mu (fun () ->
            match Hashtbl.find_opt cache key with
            | None -> ()
            | Some entry ->
                Option.iter (Hashtbl.replace cache key)
                  (Cache_state.settle ~owner ~now:refreshed_at result entry));
        (match result with
         | Ok _ -> ()
         | Error message ->
             Log.Misc.warn "dashboard metrics cache refresh failed: %s" message);
        result, refreshed_at
      in
      if background then Pool_lane.with_background run else run ())
  in
  (* Observe cancellation before the cache mutation below: the missing-key
     path evicts and installs under the mutex, and a cancel arriving between
     that mutation and [Cache_state.start] would leave an empty entry no
     owner will ever refresh. *)
  Eio.Switch.check sw;
  let view, owner =
    Stdlib.Mutex.protect dashboard_metrics_cache_mu (fun () ->
        let entry =
          match Hashtbl.find_opt cache key with
          | Some entry -> entry
          | None ->
              evict_oldest_if_full ~max_entries:dashboard_metrics_cache_max_entries
                ~age_of:Cache_state.updated_at cache;
              let entry = Cache_state.empty in
              Hashtbl.add cache key entry;
              entry
        in
        match Cache_state.admit ~now ~ttl_s:dashboard_metrics_cache_ttl_s entry with
        | Cache_state.Reuse view -> view, None
        | Cache_state.Refresh (view, plan) ->
            Eio.Switch.check sw;
            let entry, owner = Cache_state.start plan in
            Hashtbl.replace cache key entry;
            view, Some owner)
  in
  let response = cache_response ~now ~placeholder view in
  match owner with
  | None -> response
  | Some owner ->
      let was_cold = match view with
        | Cache_state.Warming _ -> true
        | Cache_state.Fresh _ | Cache_state.Stale _ -> false
      in
      if sync_first && was_cold then
        (match run_compute_and_store ~background:false owner with
         | Ok json, refreshed_at ->
             json_with_cache_metadata json
               (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
                  ~generated_at:refreshed_at ())
         | Error _, _ -> response)
      else
        (* The pre-fork check alone cannot guarantee the callback runs: Eio may
           schedule the child and then have the switch reject it before its
           body, so the child's [Fun.protect] never registers. Register the
           owner's release on the switch itself — teardown releases it whether
           or not the child ever ran, and [Cache_state.cancel] matches the
           owner identity, so the double release is a no-op. *)
        (try
           Eio.Switch.check sw;
           Eio.Switch.on_release sw (fun () -> release owner);
           Eio.Fiber.fork ~sw (fun () ->
               ignore (run_compute_and_store ~background:true owner
                 : (Yojson.Safe.t, string) result * float));
           response
         with exn ->
           release owner;
           raise exn)

let cached_dashboard_json ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  cached_dashboard_json_result ~now:Unix.gettimeofday
    ~sync_first ~sw ~cache ~key ~placeholder ~compute:(fun () -> Ok (compute ()))

module For_testing = struct
  type cache = (string, dashboard_json_cache_entry) Hashtbl.t
  let create_cache () : cache = Hashtbl.create 1
  let cached_json = cached_dashboard_json_result
end

let empty_model_metrics_json ~window ~bucket_min =
  `Assoc
    [ "window_minutes", `Int window
    ; "bucket_minutes", `Int bucket_min
    ; "total_entries", `Int 0
    ; "total_error_entries", `Int 0
    ; "cost_ledger_read", `Assoc [ "state", `String "pending" ]
    ; "latency_buckets", `List []
    ; "models", `List []
    ]

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
         let window = int_query_param req "window" ~default:30 in
         let bucket_min = int_query_param req "bucket_min" ~default:0 in
         let base_path = (Mcp_server.workspace_config state).base_path in
         let key =
           cache_key
             [ base_path; string_of_int window; string_of_int bucket_min ]
         in
         let json =
           cached_dashboard_json_result ~now:Unix.gettimeofday ~sw ~sync_first:false
             ~cache:dashboard_model_metrics_cache ~key
             ~placeholder:(empty_model_metrics_json ~window ~bucket_min)
             ~compute:(fun () ->
               let agg =
                 if bucket_min > 0 then
                   Model_inference_metrics.compute_with_buckets
                     ~base_path ~window_minutes:window ~bucket_minutes:bucket_min
                 else
                   Model_inference_metrics.compute
                     ~base_path ~window_minutes:window
               in
               Result.map Model_inference_metrics.to_json agg
               |> Result.map_error Model_inference_metrics.read_error_to_string)
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/metrics" (fun state _agent req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let window_minutes = 1440 in
         let history = cached_dashboard_json ~sw ~sync_first:false
           ~cache:dashboard_runtime_metrics_cache ~key:base_path
           ~placeholder:(`Assoc [ "state", `String "loading" ])
           ~compute:(fun () -> Model_inference_metrics.compute_runtime_metrics_json
             ~base_path ~window_minutes)
           |> redact_provider_history_cache_error in
         let _, _, runtimes = Runtime.get_default_route_and_runtimes () in
         let json = `Assoc [ "history", history;
           "specifications", `List (List.map runtime_specification_json runtimes) ] in
         Http.Response.json_value ~compress:true ~request:req json reqd)
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
         let key = cache_key [ config.base_path; string_of_int window ] in
         let json =
           cached_dashboard_json ~sw ~sync_first:false
             ~cache:dashboard_keeper_costs_cache ~key
             ~placeholder:
               (`Assoc [ "state", `String "loading"
                       ; "window_minutes", `Int window ])
             ~compute:(fun () ->
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
               let days = Server_provider_usage_history.days_of_window window in
               let key = cache_key [ config.base_path; string_of_int days ] in
               let json =
                 cached_dashboard_json ~sw ~sync_first:false
                   ~cache:dashboard_provider_history_cache ~key
                   ~placeholder:(`Assoc [ "state", `String "loading" ])
                   ~compute:(fun () ->
                     let result =
                       (* NDT-OK: compute time bounds this read-only history
                          after an asynchronous cache refresh starts. *)
                       let compute_now = Unix.gettimeofday () in
                       try Server_provider_usage_history.read config
                             ~now:compute_now ~window
                       with Eio.Cancel.Cancelled _ as exn -> raise exn
                          | exn ->
                              Log.Server.warn "provider usage history crashed: %s"
                                (Printexc.to_string exn);
                              Error "provider usage history store unavailable"
                     in
                     match result with
                     | Ok json -> json
                     | Error detail ->
                         `Assoc [ "state", `String "unavailable"
                                ; "reason", `String detail ])
               in
               `OK, redact_provider_history_cache_error json
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
           cached_dashboard_json_result ~now:Unix.gettimeofday ~sw ~sync_first:false
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
         let config = (Mcp_server.workspace_config state) in
         let key = cache_key [ config.base_path; string_of_int limit ] in
         let json =
           cached_dashboard_json ~sw ~sync_first:true
             ~cache:dashboard_keeper_decisions_cache ~key
             ~placeholder:
               (Dashboard_http_keeper.keeper_decisions_json ~config
                  ~keepers:[] ~limit ())
             ~compute:(fun () ->
               let keeper_names =
                 (match Keeper_meta_store.keeper_names_result config with
                  | Ok names -> names
                  | Error detail ->
                    Log.Keeper.warn "dashboard keeper feed: keeper names unread: %s" detail;
                    [])
               in
               let keepers =
                 List.filter_map (fun name ->
                   match Keeper_meta_store.read_meta config name with
                   | Ok (Some m) -> Some m
                   | Ok (None) | Error _ -> None
                 ) keeper_names
               in
               Dashboard_http_keeper.keeper_decisions_json ~config ~keepers
                 ~limit ())
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/keeper-decisions-log" (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = (Mcp_server.workspace_config state) in
         let key = cache_key [ config.base_path; string_of_int limit ] in
         let json =
           cached_dashboard_json ~sw ~sync_first:false
             ~cache:dashboard_keeper_decisions_log_cache ~key
             ~placeholder:
               (Dashboard_http_keeper.keeper_decisions_log_json ~config
                  ~keepers:[] ~limit ())
             ~compute:(fun () ->
               let keeper_names =
                 (match Keeper_meta_store.keeper_names_result config with
                  | Ok names -> names
                  | Error detail ->
                    Log.Keeper.warn "dashboard keeper feed: keeper names unread: %s" detail;
                    [])
               in
               let keepers =
                 List.filter_map (fun name ->
                   match Keeper_meta_store.read_meta config name with
                   | Ok (Some m) -> Some m
                   | Ok (None) | Error _ -> None
                 ) keeper_names
               in
               Dashboard_http_keeper.keeper_decisions_log_json ~config
                 ~keepers ~limit ())
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/keeper-practice" (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = (Mcp_server.workspace_config state) in
         let key = cache_key [ config.base_path; string_of_int limit ] in
         let json =
           cached_dashboard_json ~sw ~sync_first:true
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
