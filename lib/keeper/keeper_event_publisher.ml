(** MASC Event_bus publishers for runtime events.

    Publishes MASC workspace events (broadcasts, heartbeats, board
    posts, task transitions, keeper lifecycle, audit) to the MASC-owned
    Event_bus. Events follow dot-separated snake_case naming per OAS
    Custom-name convention: [masc.broadcast], [masc.heartbeat],
    [masc.keeper.lifecycle], ...

    Every publish routes to [Masc_event_bus.get ()] so the OAS/MASC
    layer boundary is preserved. OAS's [event_bus.mli:103-107]
    explicitly warns against publishing domain events onto OAS's bus.

    Wire format on SSE output keeps colon separators ("masc.broadcast")
    for dashboard compatibility — the translation is done by the SSE
    relay, not here.

    @since 2.90.0 (bus-separated since 2.353.0) *)

(* Route every publish to the MASC-owned bus. This closes the OAS boundary
   violation where MASC was publishing Custom("masc:...") onto OAS's shared
   bus. *)
let masc_publish event =
  match Masc_event_bus.get () with
  | Some mb -> Agent_sdk_metrics_bridge.publish mb event
  | None -> ()

(** Publish a broadcast event to the shared Event_bus. *)
let publish_broadcast ~agent_name ~content =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("content", `String content);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.broadcast", payload)))

(** Publish a heartbeat event to the shared Event_bus. *)
let publish_heartbeat ~agent_name ~turn ~context_pct =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("turn", `Int turn);
    ("context_pct", `Float context_pct);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.heartbeat", payload)))

(** Publish a task state change event to the shared Event_bus.
    #8605 family: [transition] is the canonical [Masc_domain.task_action]
    variant -- typos at call sites fail to compile. JSON wire format
    ("claim" / "start" / "done" / ...) is preserved via
    [Masc_domain.task_action_to_string]. Sibling refactor of #8846 (the
    Workspace-side hook for the same transition vocabulary). *)
let publish_task_transition ~agent_name ~task_id
    ~(transition : Masc_domain.task_action) =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("transition", `String (Masc_domain.task_action_to_string transition));
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.task_transition", payload)))

(** {1 Keeper Snapshot Events} *)

(** Publish a keeper snapshot event to the OAS Event_bus.
    Emitted alongside SSE broadcast in keeper_keepalive. *)
let publish_keeper_snapshot ~keeper_name
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
    \[dead_cleaned\] / \[purged\] / \[admission_denied\]) and
    the phase-derived names (\[stopped\] / \[crashed\] / \[dead\] /
    \[running\]).

    Issue #8575: the previous docstring listed only five names, so
    operators silently missed the cleanup and recovery events
    (\[reconciled\] / \[dead_cleaned\] / \[admission_denied\]) — exactly the events that signal supervisor
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
let publish_keeper_lifecycle
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

(** {1 Audit Ledger Events} *)

(** Publish a global audit ledger event to the MASC Event_bus.

    Emitted by [Audit_log.log_action] after each entry is persisted,
    giving dashboard clients a real-time stream of audit events via
    SSE without polling.  Wire event name: [masc.audit_event].

    The shape mirrors the O2 spec: [{id, ts, actor, kind, target,
    summary, severity, payload}]. *)
let publish_audit_event ~id ~ts ~actor ~kind ?target ~summary ~severity
    ?payload () =
  let target_json = Json_util.string_opt_to_json target in
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

(** {1 Runtime Execution Telemetry Events} *)

(** Publish a telemetry event when runtime execution parameters are
    successfully built during keeper pre-dispatch. The
    [keeper_telemetry_consumer] observes [Custom("telemetry_event", _)]
    on the bus and increments [masc_keeper_telemetry_events_consumed_total].
    Before this publisher existed, the Ok path of
    [build_runtime_execution] never emitted a telemetry event, so the
    counter stayed at zero despite successful turn setups. *)
let publish_runtime_execution_built
    ~keeper_name
    ~runtime_id
    ~max_context
    ~effective_budget
    ~temperature
    ~generation
  =
  let payload =
    `Assoc
      [ ("keeper_name", `String keeper_name)
      ; ("runtime_id", `String runtime_id)
      ; ("max_context", `Int max_context)
      ; ("max_context_resolution", `String (string_of_int effective_budget))
      ; ("temperature", `Float temperature)
      ; ("generation", `Int generation)
      ; ("timestamp", `Float (Time_compat.now ()))
      ]
  in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("telemetry_event", payload)))
