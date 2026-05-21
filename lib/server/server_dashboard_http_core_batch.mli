(** Dashboard batch-JSON snapshot for the operator dashboard. *)

val dashboard_batch_json : ?compact:bool -> Coord.config -> Yojson.Safe.t
