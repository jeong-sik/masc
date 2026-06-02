(** Dashboard read model for goal-loop runtime status. *)

val status_json : base_path:string -> unit -> Yojson.Safe.t
