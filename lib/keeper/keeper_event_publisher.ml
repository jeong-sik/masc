(** MASC Event_bus publishers for runtime events.

    Publishes the current keeper lifecycle and runtime audit events to the
    MASC-owned Event_bus. Events follow dot-separated snake_case naming per
    AGENT_CORE Custom-name convention.

    Every publish routes to [Event_bus_slots.get_masc ()] so the AGENT_CORE/MASC
    layer boundary is preserved. AGENT_CORE's [event_bus.mli:103-107]
    explicitly warns against publishing domain events onto AGENT_CORE's bus.

    SSE wire-name translation is owned by the relay, not this module.

    @since 2.90.0 (bus-separated since 2.353.0) *)

(* Route every publish to the MASC-owned bus. This closes the AGENT_CORE boundary
   violation where MASC was publishing Custom("masc:...") onto AGENT_CORE's shared
   bus. *)
let masc_publish event =
  match Event_bus_slots.get_masc () with
  | Some mb -> Runtime_event_bus.publish mb event
  | None ->
    Log.Misc.warn "MASC observation event was not published: event bus is not initialized"

(** {1 Keeper Lifecycle Events} *)

(** Publish a keeper keepalive lifecycle event.

    Event names are pinned by
    {!Keeper_lifecycle_events.all_event_names}, which covers both the
    custom verbs (\[started\] / \[reconciled\] / \[restarted\] /
    \[supervisor_cleaned\] / \[purged\] / \[admission_denied\]) and
    the phase-derived names (\[stopped\] / \[crashed\] / \[dead\] /
    \[running\]).

    Issue #8575: the previous docstring listed only five names, so
    operators silently missed the cleanup and recovery events
    (\[reconciled\] / \[supervisor_cleaned\] / \[admission_denied\]) — exactly the events that signal supervisor
    recovery actions where observability matters most. Subscribe to
    {!Keeper_lifecycle_events.all_event_names} to receive the full
    stream.  A sync test asserting every literal emitted by
    [Keeper_supervisor] / [Keeper_keepalive] lives in the SSOT was cited
    here as [test_types.ml :: lifecycle_events_ssot]; neither the file
    nor the test exists (#22071). *)
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
    (Agent_core.Event_bus.mk_event (Custom ("masc.keeper.lifecycle", payload)))

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
  masc_publish (Agent_core.Event_bus.mk_event (Custom ("masc.audit_event", event_payload)))

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
  =
  let payload =
    `Assoc
      [ ("keeper_name", `String keeper_name)
      ; ("runtime_id", `String runtime_id)
      ; ("max_context", `Int max_context)
      ; ("max_context_resolution", `String (string_of_int effective_budget))
      ; ("temperature", `Float temperature)
      ; ("timestamp", `Float (Time_compat.now ()))
      ]
  in
  masc_publish
    (Agent_core.Event_bus.mk_event (Custom ("telemetry_event", payload)))
