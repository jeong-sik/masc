
open Server_utils
open Server_auth

module Http = Http_server_eio

type dashboard_json_cache_entry =
  { mutable value : Yojson.Safe.t option
  ; mutable updated_at : float
  ; mutable in_flight : bool
  ; mutable last_error : string option
  }

let dashboard_metrics_cache_ttl_s = 60.0
let dashboard_metrics_cache_mu = Stdlib.Mutex.create ()
let dashboard_model_metrics_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_cost_latency_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8

let cache_key parts = String.concat "\x1f" parts

let new_cache_entry () =
  { value = None; updated_at = 0.0; in_flight = false; last_error = None }

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
    ([ "state", `String state; "generated_at", `Float generated_at ]
     @ optional_float "age_s" age_s
     @ optional_string "last_error" error)

let json_with_cache_metadata json metadata =
  match json with
  | `Assoc fields -> `Assoc (fields @ [ "cache", metadata ])
  | other -> `Assoc [ "payload", other; "cache", metadata ]

let cached_dashboard_json ~sw ~cache ~key ~placeholder ~compute =
  let now = Unix.gettimeofday () in
  let entry, response, should_refresh =
    Stdlib.Mutex.lock dashboard_metrics_cache_mu;
    let entry =
      match Hashtbl.find_opt cache key with
      | Some entry -> entry
      | None ->
          let entry = new_cache_entry () in
          Hashtbl.add cache key entry;
          entry
    in
    let age_s = now -. entry.updated_at in
    let response, should_refresh =
      match entry.value with
      | Some json when age_s <= dashboard_metrics_cache_ttl_s ->
          ( json_with_cache_metadata json
              (cache_metadata ~state:"fresh" ~generated_at:now ~age_s ()),
            false )
      | Some json ->
          let start_refresh = not entry.in_flight in
          if start_refresh then entry.in_flight <- true;
          ( json_with_cache_metadata json
              (cache_metadata ~state:"stale_refreshing" ~generated_at:now
                 ~age_s ?error:entry.last_error ()),
            start_refresh )
      | None ->
          let start_refresh = not entry.in_flight in
          if start_refresh then entry.in_flight <- true;
          ( json_with_cache_metadata placeholder
              (cache_metadata ~state:"warming" ~generated_at:now
                 ?error:entry.last_error ()),
            start_refresh )
    in
    Stdlib.Mutex.unlock dashboard_metrics_cache_mu;
    entry, response, should_refresh
  in
  if should_refresh then
    Eio.Fiber.fork ~sw (fun () ->
      let result =
        try Ok (Eio_guard.run_in_systhread compute) with
        | exn ->
            Error (Printexc.to_string exn)
      in
      let refreshed_at = Unix.gettimeofday () in
      Stdlib.Mutex.lock dashboard_metrics_cache_mu;
      (match result with
       | Ok json ->
           entry.value <- Some json;
           entry.updated_at <- refreshed_at;
           entry.last_error <- None
       | Error message ->
           Log.Misc.warn "dashboard metrics cache refresh failed: %s" message;
           entry.last_error <- Some message);
      entry.in_flight <- false;
      Stdlib.Mutex.unlock dashboard_metrics_cache_mu);
  response

let empty_model_metrics_json ~window ~bucket_min =
  let agg =
    { Model_inference_metrics.window_minutes = window
    ; bucket_minutes = bucket_min
    ; models = []
    ; total_entries = 0
    ; total_error_entries = 0
    ; latency_buckets = []
    }
  in
  Model_inference_metrics.to_json agg

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
    ; "generated_at", `Float (Unix.gettimeofday ())
    ]

let dashboard_feed_limit req =
  int_query_param req "limit" ~default:200 |> clamp ~min_v:1 ~max_v:200

let o5_agent_board_inputs (config : Coord.config) =
  let queue_depth =
    Prometheus.metric_value_or_zero Keeper_metrics.(to_string TurnQueueDepth)
      ~labels:[("channel", "autonomous_queue")] ()
    |> int_of_float
    |> max 0
  in
  let now = Unix.gettimeofday () in
  Keeper_types.keeper_names config
  |> List.filter_map (fun name ->
       match Keeper_types.read_meta config name with
       | Ok (Some meta) ->
           let blocked_on =
             match meta.runtime.last_blocker with
             | Some info ->
               let value = String.trim info.detail in
               if value = "" then
                 Some (Keeper_types.blocker_class_to_string info.klass)
               else Some value
             | None -> None
           in
           Some {
             Agent_stress.agent = meta.name;
             ctx_pressure = Operator_control_snapshot.compute_context_ratio meta;
             queue_depth = Some queue_depth;
             blocked_on;
             ts = Some now;
           }
       | Ok None | Error _ -> None)

let dashboard_heuristics_json req =
  let limit = int_query_param req "limit" ~default:100 in
  let events = Heuristic_metrics.recent limit in
  Heuristic_metrics.dashboard_feed_json ~limit events

let dashboard_heuristics_coverage_json req =
  let limit = int_query_param req "limit" ~default:100 in
  Heuristic_metrics.recent_coverage limit
  |> Heuristic_metrics.coverage_report_to_json

let dashboard_stress_json ~config req =
  let limit = int_query_param req "limit" ~default:100 in
  let events = Agent_stress.recent limit in
  let agents = o5_agent_board_inputs config in
  Agent_stress.dashboard_feed_json ~limit ~agents events

let respond_dashboard_heuristics request reqd =
  with_public_read (fun _state req reqd ->
    let json = dashboard_heuristics_json req in
    Http.Response.json ~compress:true ~request:req
      (Yojson.Safe.to_string json) reqd
  ) request reqd

let respond_dashboard_heuristics_coverage request reqd =
  with_public_read (fun _state req reqd ->
    let json = dashboard_heuristics_coverage_json req in
    Http.Response.json ~compress:true ~request:req
      (Yojson.Safe.to_string json) reqd
  ) request reqd

let respond_dashboard_stress request reqd =
  with_public_read (fun state req reqd ->
    let config = state.Mcp_server.room_config in
    let json = dashboard_stress_json ~config req in
    Http.Response.json ~compress:true ~request:req
      (Yojson.Safe.to_string json) reqd
  ) request reqd

let add_routes ~sw router =
  router
  |> Http.Router.get "/api/v1/providers" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_provider_runs.provider_inventory_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/models/metrics" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let window = int_query_param req "window" ~default:30 in
         let bucket_min = int_query_param req "bucket_min" ~default:0 in
         let base_path = state.Mcp_server.room_config.base_path in
         let key =
           cache_key
             [ base_path; string_of_int window; string_of_int bucket_min ]
         in
         let json =
           cached_dashboard_json ~sw ~cache:dashboard_model_metrics_cache ~key
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
               Model_inference_metrics.to_json agg)
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/agent-runs" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
             try
               let json = Yojson.Safe.from_string body_str in
               let open Yojson.Safe.Util in
               let provider = json |> member "provider" |> to_string in
               let model_opt = json |> member "model" |> to_string_option in
               let prompt = json |> member "prompt" |> to_string in
               match
                 Dashboard_provider_runs.start_run ~sw
                   ~net:state.Mcp_server.net ~provider ~model_opt
                   ~prompt
               with
               | Ok payload ->
                   respond_json_with_cors ~status:`Created request reqd
                     (Yojson.Safe.to_string payload)
               | Error message ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string
                        (`Assoc [ ("error", `String message) ]))
             with
             | Yojson.Json_error error ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ( "error",
                            `String ("invalid json: " ^ error) );
                        ]))
             | Yojson.Safe.Util.Type_error (error, _) ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ( "error",
                            `String ("invalid request shape: " ^ error) );
                        ])))
       ) request reqd)
  |> Http.Router.prefix_get "/api/v1/agent-runs/" (fun request reqd ->
       with_read_auth (fun _state req reqd ->
         let req_path = Http.Request.path req in
         match extract_path_param ~prefix:"/api/v1/agent-runs/" req_path with
         | None ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (`Assoc [ ("error", `String "run_id is required") ]))
         | Some run_id ->
             (match Dashboard_provider_runs.run_status_json run_id with
             | Ok payload ->
                 respond_json_with_cors request reqd
                   (Yojson.Safe.to_string payload)
             | Error message ->
                 respond_json_with_cors ~status:`Not_found request reqd
                   (Yojson.Safe.to_string
                      (`Assoc [ ("error", `String message) ])))
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-costs" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let window = int_query_param req "window" ~default:1440 in
         let config = state.Mcp_server.room_config in
         let keeper_names = Keeper_types.keeper_names config in
         let keepers =
           List.filter_map (fun name ->
             match Keeper_types.read_meta config name with
             | Ok (Some m) -> Some m
             | _ -> None
           ) keeper_names
         in
         let json =
           Dashboard_http_keeper.keeper_cost_aggregates_json
             ~config ~keepers ~window_minutes:window
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/cost-latency" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let window = int_query_param req "window" ~default:1440 in
         let base_path = state.Mcp_server.room_config.base_path in
         let json =
           cached_dashboard_json ~sw ~cache:dashboard_cost_latency_cache
             ~key:(cache_key [ base_path; string_of_int window ])
             ~placeholder:(empty_cost_latency_json ~window)
             ~compute:(fun () ->
               Model_inference_metrics.compute_cost_latency_json
                 ~base_path ~window_minutes:window)
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-decisions" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = state.Mcp_server.room_config in
         let keeper_names = Keeper_types.keeper_names config in
         let keepers =
           List.filter_map (fun name ->
             match Keeper_types.read_meta config name with
             | Ok (Some m) -> Some m
             | _ -> None
           ) keeper_names
         in
         let json =
           Dashboard_http_keeper.keeper_decisions_json
             ~config ~keepers ~limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-decisions-log" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = state.Mcp_server.room_config in
         let keeper_names = Keeper_types.keeper_names config in
         let keepers =
           List.filter_map (fun name ->
             match Keeper_types.read_meta config name with
             | Ok (Some m) -> Some m
             | _ -> None
           ) keeper_names
         in
         let json =
           Dashboard_http_keeper.keeper_decisions_log_json
             ~config ~keepers ~limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-memory-log" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let limit = dashboard_feed_limit req in
         let config = state.Mcp_server.room_config in
         let keeper_names = Keeper_types.keeper_names config in
         let keepers =
           List.filter_map (fun name ->
             match Keeper_types.read_meta config name with
             | Ok (Some m) -> Some m
             | _ -> None
           ) keeper_names
         in
         let json =
           Dashboard_http_keeper.keeper_memory_log_json
             ~config ~keepers ~limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/heuristics" respond_dashboard_heuristics
  |> Http.Router.get "/api/v1/heuristics" respond_dashboard_heuristics
  |> Http.Router.get "/api/v1/dashboard/heuristics/coverage"
       respond_dashboard_heuristics_coverage
  |> Http.Router.get "/api/v1/heuristics/coverage"
       respond_dashboard_heuristics_coverage
  |> Http.Router.get "/api/v1/dashboard/stress" respond_dashboard_stress
  |> Http.Router.get "/api/v1/agent_stress" respond_dashboard_stress
