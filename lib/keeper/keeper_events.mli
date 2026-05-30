(** Keeper_events — MASC Event_bus publishers for runtime events.

    Publishes MASC coordination events (broadcasts, heartbeats,
    task transitions, audit) to the **MASC-owned** Event_bus.
    Events follow dot-separated snake_case naming per OAS
    Custom-name convention: [masc.broadcast], [masc.heartbeat], ...

    Keeper lifecycle publishers ([publish_keeper_lifecycle],
    [publish_keeper_dead], [publish_keeper_snapshot]) moved to
    {!Keeper_lifecycle_events} to decouple keeper observability
    from the cascade module surface.

    Every publish routes to {!Masc_event_bus.get} so the OAS/MASC
    layer boundary is preserved.  OAS's [event_bus.mli:103-107]
    explicitly warns against publishing domain events onto OAS's bus.

    Wire format on SSE output keeps colon separators
    ([masc.broadcast]) for dashboard compatibility — translation
    is done by the SSE relay, not here.

    @since 2.90.0 (bus-separated since 2.353.0) *)

(** {1 Active publishers} *)

val publish_broadcast :
  agent_name:string -> content:string -> unit
(** Publishes [masc.broadcast] with payload
    [{agent_name, content, timestamp}]. *)

val publish_heartbeat :
  agent_name:string ->
  turn:int ->
  context_pct:float ->
  unit
(** Publishes [masc.heartbeat] with payload
    [{agent_name, turn, context_pct, timestamp}]. *)

val publish_task_transition :
  agent_name:string ->
  task_id:string ->
  transition:Masc_domain.task_action ->
  unit
(** Publishes [masc.task_transition] with payload
    [{agent_name, task_id, transition, timestamp}].

    [transition] is the canonical {!Masc_domain.task_action} variant
    (#8605 family) — typos at call sites fail to compile.
    Wire format ([["claim"]] / [["start"]] / [["done"]] / ...)
    preserved via {!Masc_domain.task_action_to_string}.  Sibling
    refactor of #8846 (Coord-side hook for the same transition
    vocabulary). *)

(** {1 Audit Ledger Events} *)

val publish_audit_event :
  id:string ->
  ts:string ->
  actor:string ->
  kind:string ->
  ?target:string ->
  summary:string ->
  severity:string ->
  ?payload:Yojson.Safe.t ->
  unit ->
  unit
(** Publishes [masc.audit_event] to the MASC Event_bus.

    Emitted by {!Audit_log.log_action} after each entry is persisted.
    Dashboard clients receive a real-time stream of global audit events
    via SSE without polling.

    Shape: [{id, ts, actor, kind, target?, summary, severity, payload?}]. *)
