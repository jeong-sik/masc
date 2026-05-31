(** Dashboard shell bootstrap and paths JSON helpers. *)

val dashboard_shell_paths_json : Workspace.config -> Yojson.Safe.t
val dashboard_shell_bootstrap_json : Workspace.config -> Yojson.Safe.t
