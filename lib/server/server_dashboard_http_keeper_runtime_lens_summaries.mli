(** Runtime-lens support summaries for keeper runtime trace responses. *)

val config_drift_summary_json :
  config:Workspace.config -> keeper_name:string -> Yojson.Safe.t
