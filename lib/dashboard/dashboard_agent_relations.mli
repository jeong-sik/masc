(** Dashboard_agent_relations — Proxy to GraphQL for agent
    relationship data.

    Fetches the [COLLABORATED_WITH] network and [TRUSTS] edges for an
    agent from the Second Brain GraphQL server and assembles them
    into a dashboard JSON payload.

    @since 2.113.0 *)

(** [json ~agent_name ()] queries the GraphQL server for [agent_name]'s
    collaborators, interests, and outgoing relations (public-visibility,
    first 20). GraphQL/read/schema errors are surfaced in [read_errors]
    with section-level [collaborators_known], [interests_known], and
    [relations_known] booleans; compatibility arrays remain present but
    must not be interpreted as known-empty when the matching flag is
    [false]. The payload also includes [dashboard_surface], [source],
    [retention], and [generated_at_iso] so Agent Observatory can show
    this feed's provenance. *)
val json : agent_name:string -> unit -> Yojson.Safe.t

module For_testing : sig
  val json_from_query_results
    :  agent_name:string
    -> generated_at_iso:string
    -> collaborators_result:(Yojson.Safe.t, string) result
    -> agent_result:(Yojson.Safe.t, string) result
    -> Yojson.Safe.t
end
