(** MASC Event_bus publishers for runtime events.

    Publishes MASC coordination events (broadcasts, heartbeats, board
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
    Coord-side hook for the same transition vocabulary). *)
let publish_task_transition ~agent_name ~task_id
    ~(transition : Masc_domain.task_action) =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("transition", `String (Masc_domain.task_action_to_string transition));
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.task_transition", payload)))

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
