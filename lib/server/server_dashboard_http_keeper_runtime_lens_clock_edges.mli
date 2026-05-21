(** Runtime-lens clock-edge projection.

    This module derives a causal, lane-oriented edge list from existing
    runtime-manifest rows. It does not change the raw manifest schema; callers
    can add explicit [decision.clock_refs] over time and the projection will
    prefer those values. *)

val runtime_lens_clock_edges_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t

val runtime_lens_clock_groups_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t

val runtime_lens_clock_gaps :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Server_dashboard_http_keeper_runtime_lens_swimlane.runtime_lens_gap list
