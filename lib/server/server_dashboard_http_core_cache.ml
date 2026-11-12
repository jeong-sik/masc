(** Cache key + timeout + projection-diagnostics helpers for dashboard
    HTTP core, extracted from server_dashboard_http_core.ml.

    Pure helpers + a few atomic shell-warmup state cells.  Atomic state
    is initialised once on sibling load — observably identical to the
    pre-extraction top-level lets. *)

let dashboard_request_timeout_s = 30.0

(** Standard SWR cache TTL — 60 seconds. Used by most dashboard
    endpoints for stale-while-revalidate caching. *)
let standard_cache_ttl_s = 60.0

let workspace_memory_inventory_cache_key ~base_path =
  "workspace_memory_inventory:" ^ base_path
;;

(** Deep dashboard surface cache TTL — 2 minutes. Used for mission
    and execution surfaces that involve multi-step compute. *)
let deep_surface_cache_ttl_s = 120.0

(** Shell dashboard surface cache TTL — 60 seconds. Shell state
    changes more frequently than deep surfaces. *)
let shell_surface_cache_ttl_s = 60.0

(** Keeper freshness SLO — 5 minutes. Data older than this is
    reported as stale in keeper tool-stats and tool-calls. *)
let freshness_slo_s = 300.0

(** Config cache TTL — 30 seconds. Feature flags and provider rollups
    that change infrequently. *)
let config_cache_ttl_s = 30.0

(** Live cache TTL — 30 seconds. Frequently-changing data such as
    active keeper state and agent status. *)
let live_cache_ttl_s = 30.0

(** Realtime cache TTL — 15 seconds. Near-realtime feeds where
    staleness is immediately visible. *)
let realtime_cache_ttl_s = 15.0

(** Shared dashboard projection cache TTL — 120 seconds. *)
let dashboard_projection_cache_ttl_s = 120.0

let planning_cache_prefix = "planning:"
let planning_cache_key ~base_path = planning_cache_prefix ^ base_path

(* Every cached projection of the board store. A board write drops all of
   them so the SSE-triggered refetch reads the write instead of the
   previous projection for the rest of the TTL. *)
let board_projection_cache_prefixes =
  [ "board:memory:"; "board:list:"; "board:hearths:" ]
;;

let invalidate_board_projections () =
  List.iter Dashboard_cache.invalidate_prefix board_projection_cache_prefixes
;;

(** Track whether shell cache has been populated at least once.
    Atomic.t for cross-domain visibility: read from executor pool
    worker domains via namespace-truth and warmup helpers. *)
let shell_warmed : bool Atomic.t = Atomic.make false

(** Track whether the startup shell pre-warm fiber is still building the
    first payload. Cold HTTP requests use this to serve a bootstrap payload
    instead of blocking on the same expensive shell projection. *)
let shell_warming : bool Atomic.t = Atomic.make false

(** Last-known-good shell result for graceful degradation on timeout. *)
let last_good_shell : Yojson.Safe.t Atomic.t = Atomic.make (`Assoc [])

(** Last-known-good light shell result for first-paint requests while
    full shell pre-warm is still running. *)
let last_good_shell_light : Yojson.Safe.t Atomic.t = Atomic.make (`Assoc [])

(** Wrap a dashboard computation with a configurable timeout.
    Returns a partial-response JSON on timeout instead of hanging; a
    computation that finished as the timeout expired is the response. *)
let with_dashboard_timeout ~clock compute =
  match
    Watched_work.run
      ~watcher:(fun () ->
        Eio.Time.sleep clock dashboard_request_timeout_s;
        Error `Timeout)
      (fun () -> Ok (compute ()))
  with
  | Ok v -> v
  | Error `Timeout ->
    `Assoc
      [ "error", `String "timeout"
      ; "partial", `Bool true
      ; ( "message"
        , `String
            (Printf.sprintf
               "Dashboard computation timed out after %.0fs."
               dashboard_request_timeout_s) )
      ; "generated_at", `String (Masc_domain.now_iso ())
      ]
;;

(* The directory the cached state actually lives in, so the cache is
   partitioned exactly like the store it caches. A constant partition once let
   a scope switch serve the previous workspace's projection (#24504). *)
let cache_partition_of_base_path ~base_path = Common.masc_dir_from_base_path ~base_path

let cache_partition_segment (config : Workspace.config) =
  cache_partition_of_base_path ~base_path:config.base_path
;;

let partition_cache_key ~partition prefix suffix =
  Printf.sprintf "%s:%s:%s" prefix partition suffix
;;

let dashboard_cache_key (config : Workspace.config) prefix suffix =
  partition_cache_key ~partition:(cache_partition_segment config) prefix suffix
;;

let dashboard_query_cache_value_json = function
  | Some raw ->
    let value = String.trim raw in
    if value = "" then `Null else `String value
  | None -> `Null
;;

let dashboard_query_cache_suffix fields =
  `List
    (List.map
       (fun (key, value) ->
         `List [ `String key; dashboard_query_cache_value_json value ])
       fields)
  |> Yojson.Safe.to_string
;;

let dashboard_query_cache_key config prefix fields =
  dashboard_cache_key config prefix (dashboard_query_cache_suffix fields)
;;

let tool_metrics_series_cache_prefix ~base_path =
  partition_cache_key
    ~partition:(cache_partition_of_base_path ~base_path)
    "tool_metrics_series" ""
;;

let tool_metrics_series_cache_key (config : Workspace.config) fields =
  tool_metrics_series_cache_prefix ~base_path:config.base_path
  ^ dashboard_query_cache_suffix fields
;;

let invalidate_tool_metrics_series ~base_path =
  Dashboard_cache.invalidate_prefix (tool_metrics_series_cache_prefix ~base_path)
;;

(* Keyed by base path rather than config: the schedule store's change observer
   is handed only the base path of the workspace it wrote. *)
let scheduled_automation_cache_key ~base_path =
  partition_cache_key
    ~partition:(cache_partition_of_base_path ~base_path)
    "scheduled_automation"
    (dashboard_query_cache_suffix [])
;;

(* The fleet schedule list carries the schedule runner's status and its holds,
   and the runner changes both on every tick. Cached for [live_cache_ttl_s]
   alone, the page would keep saying [ok] for that long after a tick failed,
   so the runner loop drops it each time a tick's outcome is on record
   (#38411). *)
let invalidate_scheduled_automation ~base_path =
  Dashboard_cache.invalidate (scheduled_automation_cache_key ~base_path)
;;

let dashboard_briefing_timeout_s = Env_config_runtime.Dashboard.briefing_timeout_sec

let attach_projection_diagnostics json diagnostics =
  match json with
  | `Assoc fields -> `Assoc (("projection_diagnostics", diagnostics) :: fields)
  | other -> other
;;

let projection_diagnostics_json ~surface ~started_at ~extra json =
  let build_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
  let payload_bytes = String.length (Yojson.Safe.to_string json) in
  `Assoc
    ([ "surface", `String surface
     ; "build_ms", `Int build_ms
     ; "payload_bytes", `Int payload_bytes
     ; "generated_at", `String (Masc_domain.now_iso ())
     ]
     @ extra)
;;

let with_projection_diagnostics ~surface ~started_at ~extra json =
  attach_projection_diagnostics
    json
    (projection_diagnostics_json ~surface ~started_at ~extra json)
;;
