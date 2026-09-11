(** Dashboard_agent_relations — agent relationship view.
    Second Brain GraphQL integration has been retired; returns deterministic empty relation view.
*)

(** [json ~agent_name ()] returns the agent relations payload.
    External Second Brain GraphQL is retired; this returns an empty deterministic feed.
    The payload includes [dashboard_surface], [source], [retention], and [generated_at_iso]. *)
val json : agent_name:string -> unit -> Yojson.Safe.t
