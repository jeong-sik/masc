(** Cache key + timeout + projection-diagnostics helpers for dashboard
    HTTP core, extracted from server_dashboard_http_core.ml.

    Pure helpers + a few atomic shell-warmup state cells.  Atomic state
    is initialised once on sibling load — observably identical to the
    pre-extraction top-level lets. *)

let dashboard_request_timeout_s = 30.0

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

let cache_partition_segment (_config : Coord.config) = "default"

let dashboard_cache_key (config : Coord.config) prefix suffix =
  Printf.sprintf
    "%s:%s:%s:%s"
    prefix
    config.base_path
    (cache_partition_segment config)
    suffix
;;

let dashboard_mission_timeout_s = Env_config_runtime.Dashboard.mission_timeout_sec

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
