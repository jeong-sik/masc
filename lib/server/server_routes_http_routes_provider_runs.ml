
open Server_utils
open Server_auth

module Http = Http_server_eio

let dashboard_feed_limit req =
  int_query_param req "limit" ~default:200 |> clamp ~min_v:1 ~max_v:200

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
         let agg =
           if bucket_min > 0 then
             Model_inference_metrics.compute_with_buckets
               ~base_path ~window_minutes:window ~bucket_minutes:bucket_min
           else
             Model_inference_metrics.compute
               ~base_path ~window_minutes:window
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string (Model_inference_metrics.to_json agg)) reqd
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
           Model_inference_metrics.compute_cost_latency_json
             ~base_path ~window_minutes:window
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
  |> Http.Router.get "/api/v1/dashboard/heuristics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let limit = int_query_param req "limit" ~default:100 in
         let events = Heuristic_metrics.recent limit in
         let json =
           `Assoc [
             ("limit", `Int limit);
             ("count", `Int (List.length events));
             ("events", `List events);
           ]
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/heuristics/coverage" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let limit = int_query_param req "limit" ~default:100 in
         let report = Heuristic_metrics.recent_coverage limit in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string
              (Heuristic_metrics.coverage_report_to_json report))
           reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/stress" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let limit = int_query_param req "limit" ~default:100 in
         let events = Agent_stress.recent limit in
         let json =
           `Assoc [
             ("limit", `Int limit);
             ("count", `Int (List.length events));
             ("events", `List events);
           ]
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
