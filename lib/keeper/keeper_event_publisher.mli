(** Keeper_event_publisher — MASC Event_bus publishers for runtime events.

    Publishes MASC workspace events (broadcasts, heartbeats,
    board posts, task transitions, keeper lifecycle, audit) to the
    **MASC-owned** Event_bus.  Events follow dot-separated
    snake_case naming per OAS Custom-name convention:
    [masc.broadcast], [masc.heartbeat], [masc.keeper.lifecycle],
    ...

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
    refactor of #8846 (Workspace-side hook for the same transition
    vocabulary). *)

(** {1 Keeper snapshot + lifecycle} *)

val publish_keeper_snapshot :
  keeper_name:string ->
  generation:int ->
  context_ratio:float ->
  message_count:int ->
  unit
(** Publishes [masc.keeper.snapshot] with payload
    [{keeper_name, generation, context_ratio, message_count, timestamp}].
    Emitted alongside SSE broadcast in [keeper_keepalive]. *)

val publish_keeper_lifecycle :
  event:Keeper_lifecycle_events.lifecycle_event ->
  keeper_name:string ->
  detail:string ->
  unit ->
  unit
(** Publishes [masc.keeper.lifecycle] with payload
    [{event, keeper_name, phase, detail, timestamp}].

    [event] is the unified
    {!Keeper_lifecycle_events.lifecycle_event} variant (#8856
    / #8605 family) — typos at the 16 supervisor / keepalive
    call sites fail to compile.

    {2 Wire format pinned}

    JSON wire format preserved bit-identically across the
    variant unification:
    - [Custom_event { verb; phase = None }] → [event=verb], [phase=null]
    - [Custom_event { verb; phase = Some p }] → [event=verb], [phase=p]
    - [Phase_event p] → [event=p], [phase=p]

    Subscribe to {!Keeper_lifecycle_events.all_event_names} to
    receive the full stream.  Issue #8575: prior docstring
    listed only five names, so operators silently missed
    cleanup / self-healing events ([reconciled],
    [dead_cleaned], [self_preservation], [paused_pruned]) —
    exactly the events that signal supervisor recovery actions
    where observability matters most. *)

val publish_keeper_dead :
  keeper_name:string ->
  reason:string ->
  restart_count:int ->
  last_failure_reason:string option ->
  unit ->
  unit
(** Publishes [masc.keeper.dead] with payload
    [{keeper_name, reason, restart_count, last_failure_reason, timestamp}].

    Emitted when {!Keeper_supervisor.sweep_and_recover} gives
    up on a keeper after [restart_count >= max_restarts].
    Operators should treat this as actionable: the supervisor
    will NOT retry the keeper.

    Independent from the [event="dead"] entry on
    [masc.keeper.lifecycle] (which is unstructured free-form
    [detail]) so subscribers can filter on a stable topic and
    pull the structured fields directly. *)

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

(** [max_tokens] is always represented on the wire as an integer or [null].
    The payload also carries [max_tokens_source]: [explicit_override] for
    [Some _], [omitted] for [None]. *)
val publish_runtime_execution_built :
  keeper_name:string ->
  runtime_id:string ->
  max_tokens:int option ->
  max_context:int ->
  effective_budget:int ->
  temperature:float ->
  generation:int ->
  unit
