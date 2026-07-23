(** Cache key + timeout + projection-diagnostics helpers for dashboard
    HTTP core, extracted from server_dashboard_http_core.ml.

    Pure helpers + a few atomic shell-warmup state cells.  Atomic state
    is initialised once on sibling load — observably identical to the
    pre-extraction top-level lets. *)

let dashboard_request_timeout_s = 30.0

(** Standard SWR cache TTL — 60 seconds. Used by most dashboard
    endpoints for stale-while-revalidate caching. *)
let standard_cache_ttl_s = 60.0

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

(** Feature health cache TTL — 60 seconds. Minute-scale flags with
    ~3.5s compute cost. *)
let feature_health_cache_ttl_s = 60.0

(** Shared dashboard projection cache TTL — 120 seconds. *)
let dashboard_projection_cache_ttl_s = 120.0

(** Track whether shell cache has been populated at least once.
    Atomic.t for cross-domain visibility: read from executor pool
    worker domains via namespace-truth and warmup helpers. *)
let shell_warmed : bool Atomic.t = Atomic.make false
let _shell_warmed = shell_warmed

(** Track whether the startup shell pre-warm fiber is still building the
    first payload. Cold HTTP requests use this to serve a bootstrap payload
    instead of blocking on the same expensive shell projection. *)
let shell_warming : bool Atomic.t = Atomic.make false
let _shell_warming = shell_warming

(** Last-known-good shell result for graceful degradation on timeout. *)
let last_good_shell : Yojson.Safe.t Atomic.t = Atomic.make (`Assoc [])
let _last_good_shell = last_good_shell

(** Last-known-good light shell result for first-paint requests while
    full shell pre-warm is still running. *)
let last_good_shell_light : Yojson.Safe.t Atomic.t = Atomic.make (`Assoc [])
let _last_good_shell_light = last_good_shell_light

(** Wrap a dashboard computation with a configurable timeout.
    Returns a partial-response JSON on timeout instead of hanging. *)
let with_dashboard_timeout ~clock compute =
  match
    Eio.Time.with_timeout clock dashboard_request_timeout_s (fun () -> Ok (compute ()))
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

let cache_partition_segment (_config : Workspace.config) = "default"

let dashboard_cache_key (config : Workspace.config) prefix suffix =
  Printf.sprintf
    "%s:%s:%s:%s"
    prefix
    config.base_path
    (cache_partition_segment config)
    suffix
;;

let dashboard_query_cache_segment = function
  | Some raw ->
    let value = String.trim raw in
    if value = "" then "missing" else value
  | None -> "missing"
;;

let dashboard_query_cache_value_json = function
  | Some raw ->
    let value = String.trim raw in
    if value = "" then `Null else `String value
  | None -> `Null
;;

let dashboard_query_cache_key config prefix fields =
  let suffix =
    `List
      (List.map
         (fun (key, value) ->
           `List [ `String key; dashboard_query_cache_value_json value ])
         fields)
    |> Yojson.Safe.to_string
  in
  dashboard_cache_key config prefix suffix
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

let initialized_json_opt ?(allow_initializing = false) = function
  | `Assoc fields as json ->
    (match List.assoc_opt "status" fields with
     | Some (`String "initializing") when not allow_initializing -> None
     | _ -> Some json)
  | _ -> None
;;
