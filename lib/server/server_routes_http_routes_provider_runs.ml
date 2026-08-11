
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

(* Per-cache entry ceiling. The [window]/[bucket_min] query params are folded
   into the cache key unclamped (see [add_routes]), and these endpoints are
   public reads, so distinct client-supplied values would otherwise grow each
   table without bound (memory-exhaustion vector). The legitimate dashboard
   uses a small fixed set of windows, so this ceiling is never reached in
   normal operation; past it, the least-recently-refreshed entry is evicted. *)
let dashboard_metrics_cache_max_entries = 128
let dashboard_metrics_cache_mu = Stdlib.Mutex.create ()
let dashboard_model_metrics_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_cost_latency_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_costs_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_decisions_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8
let dashboard_keeper_decisions_log_cache : (string, dashboard_json_cache_entry) Hashtbl.t = Hashtbl.create 8

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

let cached_dashboard_json ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  let now = Unix.gettimeofday () in
  let run_compute_and_store entry =
    let result =
      (* Offload via the Executor_pool, NOT [Eio_guard.run_in_systhread].
         The keeper-* computes transitively reach [Keeper_fs.ensure_dir],
         which takes the shared [dir_mu] through [Eio.Mutex.use_rw ~protect].
         On a bare systhread there is no Eio effect handler, so [Cancel.protect]
         performs [Get_context] with no handler -> [Effect.Unhandled], which
         [use_rw] turns into a poison of [dir_mu] -> every file write in the
         process then fails with [Eio.Mutex.Poisoned] (keeper persistence dies).
         Executor_pool workers run [f] inside [Eio.Switch.run] (a real fiber
         with a [Get_context] handler), so [use_rw] resolves normally; when no
         pool is set [submit_or_inline] runs inline in the calling fiber, which
         also carries an Eio context. *)
      try Ok (Executor_pool_ref.submit_or_inline compute) with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Printexc.to_string exn)
    in
    (* NDT-OK: moved cache freshness timestamp; wall-clock metadata is boundary output. *)
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
    Stdlib.Mutex.unlock dashboard_metrics_cache_mu;
    result, refreshed_at
  in
  let entry, response, should_refresh, was_cold =
    Stdlib.Mutex.lock dashboard_metrics_cache_mu;
    let entry =
      match Hashtbl.find_opt cache key with
      | Some entry -> entry
      | None ->
          evict_oldest_if_full
            ~max_entries:dashboard_metrics_cache_max_entries
            ~age_of:(fun e -> e.updated_at) cache;
          let entry = new_cache_entry () in
          Hashtbl.add cache key entry;
          entry
    in
    let age_s = now -. entry.updated_at in
    let response, should_refresh, was_cold =
      match entry.value with
      | Some json when age_s <= dashboard_metrics_cache_ttl_s ->
          ( json_with_cache_metadata json
              (cache_metadata ~state:"fresh" ~generated_at:now ~age_s ()),
            false,
            false )
      | Some json ->
          let start_refresh = not entry.in_flight in
          if start_refresh then entry.in_flight <- true;
          ( json_with_cache_metadata json
              (cache_metadata ~state:"stale_refreshing" ~generated_at:now
                 ~age_s ?error:entry.last_error ()),
            start_refresh,
            false )
      | None ->
          let start_refresh = not entry.in_flight in
          if start_refresh then entry.in_flight <- true;
          ( json_with_cache_metadata placeholder
              (cache_metadata ~state:"warming" ~generated_at:now
                 ?error:entry.last_error ()),
            start_refresh,
            true )
    in
    Stdlib.Mutex.unlock dashboard_metrics_cache_mu;
    entry, response, should_refresh, was_cold
  in
  let response =
    if should_refresh then
      if sync_first && was_cold then
        match run_compute_and_store entry with
        | Ok json, refreshed_at ->
            json_with_cache_metadata json
              (cache_metadata ~state:"fresh" ~generated_at:refreshed_at ())
        | Error _, _ -> response
      else (
        Eio.Fiber.fork ~sw (fun () ->
          (* fire-and-forget: stale-while-revalidate background refresh. *)
          ignore (run_compute_and_store entry : (Yojson.Safe.t, string) result * float));
        response)
    else
      response
  in
  response

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

let keeper_metas config =
  Keeper_meta_store.keeper_names config
  |> List.filter_map (fun name ->
       match Keeper_meta_store.read_meta config name with
       | Ok (Some keeper) -> Some keeper
       | Ok None | Error _ -> None)

(** The response-producing half of the public provider/cost dashboard
    surface.  Both HTTP adapters call this so H2 does not silently lose the
    stale-while-revalidate behavior used by H1. *)
let public_read_json ~sw ~state request =
  let config = Mcp_server.workspace_config state in
  let base_path = config.base_path in
  match Http.Request.path request with
  | "/api/v1/providers" ->
    Some (Server_dashboard_http_runtime_info.runtime_inventory_json ())
  | "/api/v1/models/metrics" ->
    let window = int_query_param request "window" ~default:30 in
    let bucket_min = int_query_param request "bucket_min" ~default:0 in
    let key = cache_key [ base_path; string_of_int window; string_of_int bucket_min ] in
    Some
      (cached_dashboard_json ~sw ~sync_first:false
         ~cache:dashboard_model_metrics_cache ~key
         ~placeholder:(empty_model_metrics_json ~window ~bucket_min)
         ~compute:(fun () ->
           let aggregate =
             if bucket_min > 0 then
               Model_inference_metrics.compute_with_buckets
                 ~base_path ~window_minutes:window ~bucket_minutes:bucket_min
             else
               Model_inference_metrics.compute ~base_path ~window_minutes:window
           in
           Model_inference_metrics.to_json aggregate))
  | "/api/v1/dashboard/keeper-costs" ->
    let window = int_query_param request "window" ~default:1440 in
    let key = cache_key [ base_path; string_of_int window ] in
    Some
      (cached_dashboard_json ~sw ~sync_first:false
         ~cache:dashboard_keeper_costs_cache ~key
         ~placeholder:
           (Dashboard_http_keeper.keeper_cost_aggregates_json ~config
              ~keepers:[] ~window_minutes:window)
         ~compute:(fun () ->
           Dashboard_http_keeper.keeper_cost_aggregates_json ~config
             ~keepers:(keeper_metas config) ~window_minutes:window))
  | "/api/v1/dashboard/cost-latency" ->
    let window = int_query_param request "window" ~default:1440 in
    Some
      (cached_dashboard_json ~sw ~sync_first:false
         ~cache:dashboard_cost_latency_cache
         ~key:(cache_key [ base_path; string_of_int window ])
         ~placeholder:(empty_cost_latency_json ~window)
         ~compute:(fun () ->
           Model_inference_metrics.compute_cost_latency_json
             ~base_path ~window_minutes:window))
  | "/api/v1/dashboard/keeper-decisions" ->
    let limit = dashboard_feed_limit request in
    let key = cache_key [ base_path; string_of_int limit ] in
    Some
      (cached_dashboard_json ~sw ~sync_first:true
         ~cache:dashboard_keeper_decisions_cache ~key
         ~placeholder:
           (Dashboard_http_keeper.keeper_decisions_json ~config ~keepers:[] ~limit ())
         ~compute:(fun () ->
           Dashboard_http_keeper.keeper_decisions_json ~config
             ~keepers:(keeper_metas config) ~limit ()))
  | "/api/v1/dashboard/keeper-decisions-log" ->
    let limit = dashboard_feed_limit request in
    let key = cache_key [ base_path; string_of_int limit ] in
    Some
      (cached_dashboard_json ~sw ~sync_first:false
         ~cache:dashboard_keeper_decisions_log_cache ~key
         ~placeholder:
           (Dashboard_http_keeper.keeper_decisions_log_json ~config ~keepers:[]
              ~limit ())
         ~compute:(fun () ->
           Dashboard_http_keeper.keeper_decisions_log_json ~config
             ~keepers:(keeper_metas config) ~limit ()))
  | _ -> None

let handle_public_read ~sw state request reqd =
  match public_read_json ~sw ~state request with
  | Some json -> Http.Response.json_value ~compress:true ~request json reqd
  | None ->
    Http.Response.json_value ~status:`Not_found ~request
      (`Assoc [ ("error", `String "unknown provider dashboard endpoint") ]) reqd

let add_routes ~sw router =
  router
  |> Http.Router.get "/api/v1/providers" (fun request reqd ->
       with_public_read (handle_public_read ~sw) request reqd)
  |> Http.Router.get "/api/v1/models/metrics" (fun request reqd ->
       with_public_read (handle_public_read ~sw) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-costs" (fun request reqd ->
       with_public_read (handle_public_read ~sw) request reqd)
  |> Http.Router.get "/api/v1/dashboard/cost-latency" (fun request reqd ->
       with_public_read (handle_public_read ~sw) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-decisions" (fun request reqd ->
       with_public_read (handle_public_read ~sw) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-decisions-log" (fun request reqd ->
       with_public_read (handle_public_read ~sw) request reqd)
