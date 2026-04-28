(** Relation_materializer — record agent collaboration edges to
    Neo4j (via GraphQL) when MASC lifecycle events fire.

    Both entry points dispatch a single batched GraphQL mutation
    (alias-batched: 20 peers = 1 HTTP request) and detach into an
    Eio fiber when an Eio runtime is available. They never block
    the caller and never raise — failures are logged via
    [Log.Misc.error] and dropped.

    Internal helpers ([log_err], [build_batch_mutation],
    [record_collaborations_async]) are hidden — callers consume
    only the two lifecycle hooks below, which {!Coord_hooks} wires
    in via [Atomic.set] in [Coord]'s init.

    @since 2.112.0 *)

val on_agent_leave :
  leaving_agent:string ->
  active_agents:string list ->
  unit
(** When an agent leaves a MASC room, record [COLLABORATED_WITH]
    edges between [leaving_agent] and every other member of
    [active_agents] (the leaver itself is filtered out). No-op
    when no peers remain. *)

val on_task_done :
  assignee:string ->
  active_agents:string list ->
  unit
(** When a task completes, record collaboration edges between the
    [assignee] and every other member of [active_agents]
    (the assignee itself is filtered out). No-op when no peers
    remain. *)
