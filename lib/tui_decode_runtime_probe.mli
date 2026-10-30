(** Runtime probe wire models and observation lookup. *)

(** Whether the non-blocking runtime-probe route served a cached reading or
    scheduled background work. The wire vocabulary is closed so a producer
    change cannot silently look fresh. *)
type runtime_probe_refresh_state =
  | Runtime_probe_fresh
  | Runtime_probe_recent
  | Runtime_probe_served_stale
  | Runtime_probe_warming_up

(** Fleet-level reachability verdict published by the runtime inventory
    projection. This is provider metadata reachability, not a completion or
    lane failover verdict. *)
type runtime_probe_status =
  | Runtime_probe_reachable
  | Runtime_probe_no_http_runtimes
  | Runtime_probe_degraded
  | Runtime_probe_unreachable
  | Runtime_probe_warming

type runtime_provider_status =
  | Runtime_provider_reachable
  | Runtime_provider_missing_auth
  | Runtime_provider_auth_failed
  | Runtime_provider_network_error
  | Runtime_provider_server_error
  | Runtime_provider_endpoint_not_found
  | Runtime_provider_http_error
  | Runtime_provider_unknown_http_status
  | Runtime_provider_skipped_cli
  | Runtime_provider_skipped_native_auth
  | Runtime_provider_invalid_endpoint
  | Runtime_provider_invalid_execution_transport

type runtime_probe_transport =
  | Runtime_probe_http
  | Runtime_probe_cli

type runtime_provider_probe = {
  rpp_runtime_id : string;
  rpp_transport : runtime_probe_transport;
  rpp_status : runtime_provider_status;
  rpp_reachable : bool option;
  rpp_http_status : int option;
  rpp_latency_ms : float option;
  rpp_error : string option;
  rpp_checked_at : string;
}

type runtime_probe_summary = {
  rpsu_runtimes : int;
  rpsu_probed : int;
  rpsu_reachable : int;
  rpsu_failed : int;
  rpsu_skipped : int;
  rpsu_default_runtime_id : string option;
}

type runtime_probe_snapshot = {
  rps_generated_at : string;
  rps_refreshed_at_unix : float option;
  rps_cache_ttl_sec : float;
  rps_cache_age_sec : float option;
  rps_cache_hit : bool;
  rps_refresh_state : runtime_probe_refresh_state;
  rps_status : runtime_probe_status;
  rps_probe_ok : bool;
  rps_checked_at : string;
  rps_summary : runtime_probe_summary;
  rps_providers : runtime_provider_probe list;
  rps_errors : string list;
  rps_observations : string list;
  rps_limitations : string list;
}

val runtime_probe_refresh_state_to_string : runtime_probe_refresh_state -> string
val runtime_probe_status_of_string :
  string -> (runtime_probe_status, string) result
(** The probe's own status, as [Server_dashboard_http_runtime_info] writes it:
    the live summary picks between ["ok"], ["idle"], ["degraded"] and
    ["unavailable"], the failure envelope writes ["unreachable"], and the
    cold-start envelope writes ["warming_up"].

    Exported so the contract can be pinned against that list. It drifted from
    it once -- this read ["reachable"] and ["no_http_runtimes"], which nothing
    writes, so every live response failed to decode and the Runtime surface
    drew every candidate as unobserved. *)

val runtime_probe_status_to_string : runtime_probe_status -> string
(** The word the wire uses, so a badge drawn from this names the reading the
    server named. Many-to-one: ["unavailable"] and ["unreachable"] read as one
    status and write back as ["unreachable"]. *)

val runtime_provider_status_to_string : runtime_provider_status -> string

val decode_runtime_probe_snapshot :
  Yojson.Safe.t -> (runtime_probe_snapshot, string) result
(** Strict decoder for [GET /api/v1/dashboard/runtime-probe]. It accepts only
    the producer's closed status vocabularies, requires the cache and provider
    fields the Runtime surface draws, and rejects count/reachability/default
    identity contradictions instead of repairing them locally. *)

(** Look up one provider in the supplied probe observation. An absent probe
    remains unobserved; this module does not depend on its UI container. *)
val runtime_probe_for_id : runtime_probe_snapshot option -> runtime_id:string -> runtime_provider_probe option
