(** Runtime-lens gap detection. *)

(** [checkpoint_owner] is who held the turn's resumable state
    ({!Server_dashboard_http_keeper_runtime_lens_swimlane.finished_turns_checkpoint_owner}).
    Lane gaps ask only for the events the turn owes. *)
val runtime_lens_gaps :
  terminal_event_present:bool ->
  config_drift:Yojson.Safe.t ->
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Server_dashboard_http_keeper_runtime_lens_swimlane.runtime_lens_gap list
