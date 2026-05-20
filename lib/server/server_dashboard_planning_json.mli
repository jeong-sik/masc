(** Dashboard planning + goals JSON. *)

val dashboard_planning_http_json : config:Coord.config -> Yojson.Safe.t
val dashboard_goals_tree_http_json : config:Coord.config -> Yojson.Safe.t
val dashboard_goals_snapshot_json : config:Coord.config -> Yojson.Safe.t
