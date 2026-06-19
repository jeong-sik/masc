(** Operator broadcast + cache state cluster for dashboard HTTP core,
    extracted from server_dashboard_http_core.ml. *)

open Server_auth
open Server_dashboard_http_cache
open Dashboard_http_helpers


(* --- Operator proactive refresh ---
   Default (no-param) requests are served from a background-refreshed ref.
   Parameterized requests fall back to on-demand compute with SWR cache.

   Using Proactive_refresh gives circuit breaker + exponential backoff on
   repeated failures, matching the pattern used by execution and mission loops.

   Interval: 10s (was 120s). Even if compute takes ~8s, the ref is updated
   every ~18s worst-case, which is acceptable for dashboard SSE polling. *)

(* Late-bound broadcast refs — set by server_dashboard_http.ml after
   Sse module is in scope.  Same pattern as _broadcast_workspace_truth_ref. *)
let operator_snapshot_broadcast_ref : (Yojson.Safe.t -> unit) ref =
  ref (fun (_json : Yojson.Safe.t) -> ())
;;

let _operator_snapshot_broadcast_ref = operator_snapshot_broadcast_ref

let operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref =
  ref (fun (_json : Yojson.Safe.t) -> ())
;;

let _operator_digest_broadcast_ref = operator_digest_broadcast_ref

let operator_snapshot_cache =
  create_cached_surface
    (`Assoc
        [ "status", `String "initializing"
        ; "generated_at", `String (Masc_domain.now_iso ())
        ])
;;

let _operator_snapshot_cache = operator_snapshot_cache

let operator_digest_cache =
  create_cached_surface
    (`Assoc
        [ "health", `String "initializing"
        ; "generated_at", `String (Masc_domain.now_iso ())
        ])
;;

let _operator_digest_cache = operator_digest_cache

let operator_refresh_interval_s =
  float_of_env_default
    "MASC_OPERATOR_REFRESH_INTERVAL_S"
    ~default:60.0
    ~min_v:10.0
    ~max_v:600.0
;;

let operator_snapshot_extra () =
  [ "readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json () ]
;;
