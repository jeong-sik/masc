(** Cascade_events — MASC Event_bus publishers for runtime / social
    events.

    Publishes MASC coordination events (broadcasts, heartbeats,
    board posts, task transitions, keeper lifecycle, trust /
    reputation) to the **MASC-owned** Event_bus.  Events follow
    dot-separated snake_case naming per OAS Custom-name
    convention: [masc.broadcast], [masc.heartbeat],
    [masc.keeper.lifecycle], ...

    The [bus] argument is accepted for backward compatibility
    but ignored — every publish routes to
    {!Masc_event_bus.get} so the OAS/MASC layer boundary is
    preserved regardless of the caller's bus reference.  OAS's
    [event_bus.mli:103-107] explicitly warns against publishing
    domain events onto OAS's bus.

    Wire format on SSE output keeps colon separators
    ([masc.broadcast]) for dashboard compatibility — translation
    is done by the SSE relay, not here.

    @since 2.90.0 (bus-separated since 2.353.0) *)

(** {1 Active publishers} *)

val publish_broadcast :
  Agent_sdk.Event_bus.t -> agent_name:string -> content:string -> unit
(** Publishes [masc.broadcast] with payload
    [{agent_name, content, timestamp}]. *)

val publish_heartbeat :
  Agent_sdk.Event_bus.t ->
  agent_name:string ->
  turn:int ->
  context_pct:float ->
  unit
(** Publishes [masc.heartbeat] with payload
    [{agent_name, turn, context_pct, timestamp}]. *)

val publish_task_transition :
  Agent_sdk.Event_bus.t ->
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

(** {1 Keeper snapshot + lifecycle} *)

val publish_keeper_snapshot :
  Agent_sdk.Event_bus.t ->
  keeper_name:string ->
  generation:int ->
  context_ratio:float ->
  message_count:int ->
  unit
(** Publishes [masc.keeper.snapshot] with payload
    [{keeper_name, generation, context_ratio, message_count, timestamp}].
    Emitted alongside SSE broadcast in [keeper_keepalive]. *)

val publish_keeper_lifecycle :
  Agent_sdk.Event_bus.t ->
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
  Agent_sdk.Event_bus.t ->
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

(** {1 Autonomy lifecycle (deprecated — no producer)} *)

val publish_agent_selected :
  Agent_sdk.Event_bus.t ->
  agent_name:string ->
  trigger:string ->
  thompson_score:float ->
  final_score:float ->
  unit
[@@deprecated "Unused since #1060 (no producer wired). Tracked \
               as 'mark scaffolding' tier of #8857; planned \
               wiring in Thompson autonomy RFC (open)."]

val publish_agent_decision :
  Agent_sdk.Event_bus.t ->
  agent_name:string ->
  action:string ->
  trigger_reason:string ->
  unit
[@@deprecated "Unused since #1060 (no producer wired). Tracked \
               as 'mark scaffolding' tier of #8857; planned \
               wiring in Thompson autonomy RFC (open)."]

val publish_agent_action_executed :
  Agent_sdk.Event_bus.t ->
  agent_name:string ->
  action:string ->
  success:bool ->
  unit
[@@deprecated "Unused since #1060 (no producer wired). Tracked \
               as 'mark scaffolding' tier of #8857; planned \
               wiring in Thompson autonomy RFC (open)."]

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

(** {1 Phase 4 social (deprecated — no producer)} *)

val publish_trust_updated :
  Agent_sdk.Event_bus.t ->
  agent_a:string ->
  agent_b:string ->
  trust_score:float ->
  unit
[@@deprecated "Unused since #1060 (no producer wired). Tracked \
               as 'mark scaffolding' tier of #8857; planned \
               wiring with Phase 4 social network feature \
               (open)."]

val publish_reputation_changed :
  Agent_sdk.Event_bus.t ->
  agent_name:string ->
  old_score:float ->
  new_score:float ->
  trend:string ->
  unit
[@@deprecated "Unused since #1060 (no producer wired). Tracked \
               as 'mark scaffolding' tier of #8857; planned \
               wiring with Phase 4 social network feature \
               (open)."]
