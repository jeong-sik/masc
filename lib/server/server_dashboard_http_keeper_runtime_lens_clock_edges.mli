(** Runtime-lens clock-edge projection.

    This module derives a causal, lane-oriented edge list from existing
    runtime-manifest rows. It does not change the raw manifest schema; callers
    can add explicit [decision.clock_refs] over time and the projection will
    prefer those values. *)

val clock_edge_jsons :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t list

val runtime_lens_clock_edges_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t
