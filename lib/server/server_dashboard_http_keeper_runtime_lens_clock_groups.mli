(** Runtime-lens clock-group projection and gap detection.

    Derives grouped clock edges (turns, batches, attempts, checkpoints,
    compactions, memory injections, event-bus correlations) from the edge
    stream produced by {!Server_dashboard_http_keeper_runtime_lens_clock_edges}. *)

val runtime_lens_clock_groups_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t

val runtime_lens_clock_gaps :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Server_dashboard_http_keeper_runtime_lens_swimlane.runtime_lens_gap list
