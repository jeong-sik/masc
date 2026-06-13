(** Dashboard batch-JSON snapshot for the operator dashboard. *)

val dashboard_batch_json : ?compact:bool -> Workspace.config -> Yojson.Safe.t
