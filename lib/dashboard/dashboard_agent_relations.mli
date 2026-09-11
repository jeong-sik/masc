(** Dashboard_agent_relations — agent relationship view. *)

(** [json ~agent_name ()] returns the agent relations payload.
    The payload includes [dashboard_surface], [source], [retention], and [generated_at_iso]. *)
val json : agent_name:string -> unit -> Yojson.Safe.t
