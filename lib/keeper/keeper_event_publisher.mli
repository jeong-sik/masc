(** Keeper_event_publisher — MASC Event_bus publishers for runtime events.

    Publishes the current keeper lifecycle and runtime audit events to the
    **MASC-owned** Event_bus. Events follow the AGENT_CORE Custom-name convention.

    Every publish routes to {!Event_bus_slots.get_masc} so the AGENT_CORE/MASC
    layer boundary is preserved.  AGENT_CORE's [event_bus.mli:103-107]
    explicitly warns against publishing domain events onto AGENT_CORE's bus.

    SSE wire-name translation is done by the relay, not here.

    @since 2.90.0 (bus-separated since 2.353.0) *)

(** {1 Keeper lifecycle} *)

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
    cleanup / recovery events ([reconciled], [supervisor_cleaned]) —
    exactly the events that signal supervisor recovery actions
    where observability matters most. *)

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

val publish_runtime_execution_built :
  keeper_name:string ->
  runtime_id:string ->
  max_context:int ->
  effective_budget:int ->
  temperature:float ->
  unit
