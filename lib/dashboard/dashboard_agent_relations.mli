(** Dashboard_agent_relations — Proxy to GraphQL for agent
    relationship data.

    Fetches the [COLLABORATED_WITH] network and [TRUSTS] edges for an
    agent from the Second Brain GraphQL server and assembles them
    into a dashboard JSON payload.

    @since 2.113.0 *)

(** [json ~agent_name ()] queries the GraphQL server for [agent_name]'s
    collaborators, interests, and outgoing relations (public-visibility,
    first 20) with an 8-second per-query timeout. On GraphQL error the
    affected section falls back to an empty list and the surrounding
    payload is still returned. The payload also includes
    [dashboard_surface], [source], [retention], and [generated_at_iso] so
    Agent Observatory can show this feed's provenance. *)
val json : agent_name:string -> unit -> Yojson.Safe.t
