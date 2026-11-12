(** Shared Operator read diagnostics and failure-only retry cadence. *)

open Dashboard_http_helpers

let operator_digest_cache ~state =
  Server_dashboard_operator_digest_observation.cache
    (Server_dashboard_operator_digest_observation.owner_for_scope ~state
      (Mcp_server.workspace_scope state))
;;

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
