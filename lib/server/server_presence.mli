(** Shared presence projections for the HTTP servers. *)

val last_seen_ms : context:string -> Masc_domain.agent -> Int64.t
(** Milliseconds-since-epoch projection of [agent.last_seen] for presence
    rows. An unparsable timestamp maps to [0L] after a warning tagged with
    [context]. The IDE and dashboard presence endpoints share this policy
    so the same agent cannot render different presence values per surface. *)
