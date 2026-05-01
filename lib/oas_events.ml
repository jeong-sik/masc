(** MASC Event_bus publishers for runtime/social events.

    Publishes MASC coordination events (broadcasts, heartbeats, board
    posts, task transitions, keeper lifecycle, trust/reputation) to the
    MASC-owned Event_bus. Events follow dot-separated snake_case naming
    per OAS Custom-name convention: [masc.broadcast], [masc.heartbeat],
    [masc.keeper.lifecycle], ...

    The [bus] argument is accepted for backward compatibility but
    ignored: every publish routes to [Masc_event_bus.get ()] so the
    OAS/MASC layer boundary is preserved regardless of the caller's
    bus reference. OAS's [event_bus.mli:103-107] explicitly warns
    against publishing domain events onto OAS's bus.

    Wire format on SSE output keeps colon separators ("masc.broadcast")
    for dashboard compatibility — the translation is done by the SSE
    relay, not here.

    @since 2.90.0 (bus-separated since 2.353.0) *)

(* Route every publish to the MASC-owned bus. Caller-passed [bus] is
   ignored — this closes the OAS boundary violation where MASC was
   publishing Custom("masc:...") onto OAS's shared bus. *)
let masc_publish event =
  match Masc_event_bus.get () with
  | Some mb -> Oas_bus_instrument.publish mb event
  | None -> ()

(** Publish a broadcast event to the shared Event_bus. *)
let publish_broadcast (_bus : Agent_sdk.Event_bus.t) ~agent_name ~content =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("content", `String content);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.broadcast", payload)))

(** Publish a heartbeat event to the shared Event_bus. *)
let publish_heartbeat (_bus : Agent_sdk.Event_bus.t) ~agent_name ~turn ~context_pct =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("turn", `Int turn);
    ("context_pct", `Float context_pct);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.heartbeat", payload)))

(** Publish a task state change event to the shared Event_bus.
    #8605 family: [transition] is the canonical [Types.task_action]
    variant -- typos at call sites fail to compile. JSON wire format
    ("claim" / "start" / "done" / ...) is preserved via
    [Types.task_action_to_string]. Sibling refactor of #8846 (the
    Coord-side hook for the same transition vocabulary). *)
let publish_task_transition (_bus : Agent_sdk.Event_bus.t) ~agent_name ~task_id
    ~(transition : Types.task_action) =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("transition", `String (Types.task_action_to_string transition));
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.task_transition", payload)))

(** {1 Autonomy Agent Lifecycle Events}

    These three publishers were scaffolded in #1060 (OAS v0.23
    integration, 2026-03-16) for the Thompson autonomy decision pipeline
    but the producer side was never wired. They are kept (rather than
    deleted like the truly-dead surfaces in #8857 [delete] tier)
    because the Thompson autonomy area is still an open RFC. Tag with
    @deprecated so consumers see the no-producer signal at compile time
    if they try to subscribe; remove the annotations when a producer
    finally lands. *)

(** Publish an agent selection event (Thompson Sampling result).
    Emitted after [select_agents_with_thompson] in keeper_heartbeat.
    @deprecated Unused since #1060 (no producer wired). Tracked as
    [mark scaffolding] tier of #8857; planned wiring in Thompson
    autonomy RFC (open). *)
let publish_agent_selected (_bus : Agent_sdk.Event_bus.t) ~agent_name ~trigger
    ~thompson_score ~final_score =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("trigger", `String trigger);
    ("thompson_score", `Float thompson_score);
    ("final_score", `Float final_score);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.autonomy.agent_selected", payload)))

(** Publish an agent action decision event (MODEL decision result).
    Emitted after MODEL decides post/comment/upvote/skip.
    @deprecated Unused since #1060 (no producer wired). Tracked as
    [mark scaffolding] tier of #8857; planned wiring in Thompson
    autonomy RFC (open). *)
let publish_agent_decision (_bus : Agent_sdk.Event_bus.t) ~agent_name ~action
    ~trigger_reason =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("action", `String action);
    ("trigger_reason", `String trigger_reason);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.autonomy.agent_decision", payload)))

(** Publish an action execution result event.
    Emitted after an agent's action (post/comment/upvote) completes.
    @deprecated Unused since #1060 (no producer wired). Tracked as
    [mark scaffolding] tier of #8857; planned wiring in Thompson
    autonomy RFC (open). *)
let publish_agent_action_executed (_bus : Agent_sdk.Event_bus.t) ~agent_name
    ~action ~success =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("action", `String action);
    ("success", `Bool success);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.autonomy.agent_action_executed", payload)))

(** {1 Keeper Snapshot Events} *)

(** Publish a keeper snapshot event to the OAS Event_bus.
    Emitted alongside SSE broadcast in keeper_keepalive. *)
let publish_keeper_snapshot (_bus : Agent_sdk.Event_bus.t) ~keeper_name
    ~generation ~context_ratio ~message_count =
  let payload = `Assoc [
    ("keeper_name", `String keeper_name);
    ("generation", `Int generation);
    ("context_ratio", `Float context_ratio);
    ("message_count", `Int message_count);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.keeper.snapshot", payload)))

(** {1 Keeper Lifecycle Events} *)

(** Publish a keeper keepalive lifecycle event.

    Event names are pinned by
    {!Keeper_lifecycle_events.all_event_names}, which covers both the
    custom verbs (\[started\] / \[reconciled\] / \[restarted\] /
    \[dead_cleaned\] / \[self_preservation\] / \[paused_pruned\]) and
    the phase-derived names (\[stopped\] / \[crashed\] / \[dead\] /
    \[running\]).

    Issue #8575: the previous docstring listed only five names, so
    operators silently missed the cleanup and self-healing events
    (\[reconciled\] / \[dead_cleaned\] / \[self_preservation\] /
    \[paused_pruned\]) — exactly the events that signal supervisor
    recovery actions where observability matters most. Subscribe to
    {!Keeper_lifecycle_events.all_event_names} to receive the full
    stream; the sync test in [test_types.ml ::
    lifecycle_events_ssot] asserts every literal still emitted by
    [Keeper_supervisor] / [Keeper_keepalive] lives in the SSOT. *)
(* #8856 / #8605 family: [event] is now the unified
   [Keeper_lifecycle_events.lifecycle_event] variant -- typos at the
   16 supervisor/keepalive call sites fail to compile. JSON wire
   format ("event" + optional "phase" field) is preserved
   bit-identically:
     - Custom_event { verb; phase = None }  -> event=verb, phase=null
     - Custom_event { verb; phase = Some p } -> event=verb, phase=p
     - Phase_event p                          -> event=p, phase=p
   The legacy ?phase optional argument is folded into the variant. *)
let publish_keeper_lifecycle (_bus : Agent_sdk.Event_bus.t)
    ~(event : Keeper_lifecycle_events.lifecycle_event)
    ~keeper_name ~detail () =
  let phase_json =
    match Keeper_lifecycle_events.lifecycle_event_phase event with
    | Some phase ->
      `String (Keeper_state_machine.phase_to_string phase)
    | None -> `Null
  in
  let event_str = Keeper_lifecycle_events.lifecycle_event_to_string event in
  let payload = `Assoc [
    ("event", `String event_str);
    ("keeper_name", `String keeper_name);
    ("phase", phase_json);
    ("detail", `String detail);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.keeper.lifecycle", payload)))

(** Publish a structured keeper-Dead event.

    Emitted when [Keeper_supervisor.sweep_and_recover] gives up on a keeper
    after [restart_count >= max_restarts]. Operators should treat this as
    actionable: the supervisor will NOT retry the keeper. Independent from
    the [event="dead"] entry on [masc.keeper.lifecycle] (which is unstructured
    free-form [detail]) so subscribers can filter on a stable topic and pull
    the structured fields directly. Topic: [masc.keeper.dead]. *)
let publish_keeper_dead (_bus : Agent_sdk.Event_bus.t)
    ~keeper_name ~reason ~restart_count ~last_failure_reason () =
  let last_failure_json =
    match last_failure_reason with
    | Some s -> `String s
    | None -> `Null
  in
  let payload = `Assoc [
    ("keeper_name", `String keeper_name);
    ("reason", `String reason);
    ("restart_count", `Int restart_count);
    ("last_failure_reason", last_failure_json);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.keeper.dead", payload)))

(** {1 Audit Ledger Events} *)

(** Publish a global audit ledger event to the MASC Event_bus.

    Emitted by [Audit_log.log_action] after each entry is persisted,
    giving dashboard clients a real-time stream of audit events via
    SSE without polling.  Wire event name: [masc.audit_event].

    The shape mirrors the O2 spec: [{id, ts, actor, kind, target,
    summary, severity, payload}]. *)
let publish_audit_event ~id ~ts ~actor ~kind ?target ~summary ~severity
    ?payload () =
  let target_json = match target with
    | Some t -> `String t
    | None -> `Null
  in
  let payload_json = match payload with
    | Some p -> p
    | None -> `Null
  in
  let event_payload = `Assoc [
    ("id", `String id);
    ("ts", `String ts);
    ("actor", `String actor);
    ("kind", `String kind);
    ("target", target_json);
    ("summary", `String summary);
    ("severity", `String severity);
    ("payload", payload_json);
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.audit_event", event_payload)))

(** {1 Phase 4: Social Events}

    These two publishers were scaffolded in #1060 (OAS v0.23
    integration, 2026-03-16) for the Phase 4 social network feature
    (trust + reputation between agents). The producer side was never
    wired and Phase 4 has not shipped. Tagged @deprecated so consumers
    see the no-producer signal at compile time; remove the annotations
    when Phase 4 producers land. Tracked as [mark scaffolding] tier
    of #8857. *)

(** Publish a trust score update between two agents.
    @deprecated Unused since #1060 (no producer wired). Tracked as
    [mark scaffolding] tier of #8857; planned wiring with Phase 4
    social network feature (open). *)
let publish_trust_updated (_bus : Agent_sdk.Event_bus.t) ~agent_a ~agent_b ~trust_score =
  let payload = `Assoc [
    ("agent_a", `String agent_a);
    ("agent_b", `String agent_b);
    ("trust_score", `Float trust_score);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.trust_updated", payload)))

(** Publish a reputation change event.
    @deprecated Unused since #1060 (no producer wired). Tracked as
    [mark scaffolding] tier of #8857; planned wiring with Phase 4
    social network feature (open). *)
let publish_reputation_changed (_bus : Agent_sdk.Event_bus.t) ~agent_name ~old_score ~new_score ~trend =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("old_score", `Float old_score);
    ("new_score", `Float new_score);
    ("trend", `String trend);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.reputation_changed", payload)))
