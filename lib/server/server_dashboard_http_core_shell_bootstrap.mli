(** Dashboard shell bootstrap and paths JSON helpers. *)

val dashboard_shell_paths_json : Coord.config -> Yojson.Safe.t
val dashboard_shell_bootstrap_json : Coord.config -> Yojson.Safe.t
