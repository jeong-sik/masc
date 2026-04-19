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

(** Publish a board post event to the shared Event_bus. *)
let publish_board_post (_bus : Agent_sdk.Event_bus.t) ~agent_name ~post_id =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("post_id", `String post_id);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.board_post", payload)))

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

(** Publish a heartbeat recovery event to the OAS Event_bus.
    Emitted when a previously timed-out agent re-activates. *)
let publish_heartbeat_recovered (_bus : Agent_sdk.Event_bus.t) ~agent_name ~previous_timeout_s =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("previous_timeout_s", `Float previous_timeout_s);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.heartbeat_recovered", payload)))

(** {1 Autonomy Agent Lifecycle Events} *)

(** Publish an agent selection event (Thompson Sampling result).
    Emitted after [select_agents_with_thompson] in keeper_heartbeat. *)
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
    Emitted after MODEL decides post/comment/upvote/skip. *)
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
    Emitted after an agent's action (post/comment/upvote) completes. *)
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
let publish_keeper_lifecycle (_bus : Agent_sdk.Event_bus.t) ?phase ~event
    ~keeper_name ~detail () =
  let phase_json =
    match phase with
    | Some phase ->
      `String (Keeper_state_machine.phase_to_string phase)
    | None -> `Null
  in
  let payload = `Assoc [
    ("event", `String event);
    ("keeper_name", `String keeper_name);
    ("phase", phase_json);
    ("detail", `String detail);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.keeper.lifecycle", payload)))

(** {1 Phase 4: Social Events} *)

(** Publish a trust score update between two agents. *)
let publish_trust_updated (_bus : Agent_sdk.Event_bus.t) ~agent_a ~agent_b ~trust_score =
  let payload = `Assoc [
    ("agent_a", `String agent_a);
    ("agent_b", `String agent_b);
    ("trust_score", `Float trust_score);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.trust_updated", payload)))

(** Publish a reputation change event. *)
let publish_reputation_changed (_bus : Agent_sdk.Event_bus.t) ~agent_name ~old_score ~new_score ~trend =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("old_score", `Float old_score);
    ("new_score", `Float new_score);
    ("trend", `String trend);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.reputation_changed", payload)))

(** Publish an institution episode event. *)
let publish_institution_episode (_bus : Agent_sdk.Event_bus.t) ~episode_id ~event_type ~participants =
  let payload = `Assoc [
    ("episode_id", `String episode_id);
    ("event_type", `String event_type);
    ("participant_count", `Int (List.length participants));
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish (Agent_sdk.Event_bus.mk_event (Custom ("masc.institution_episode", payload)))

(** {1 Harness Observability Events (#3165)} *)

(** Publish a verdict-recorded event.
    Emitted after [Eval_calibration.record_verdict] persists a verdict. *)
let publish_verdict_recorded (_bus : Agent_sdk.Event_bus.t) ~agent_name ~task_id
    ~gate ~verdict =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("gate", `String gate);
    ("verdict", `String verdict);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.harness.verdict_recorded", payload)))

(** Publish a pre-compaction observation event.
    Emitted before [Context_compact_oas.compact] runs in keeper. *)
let publish_pre_compact (_bus : Agent_sdk.Event_bus.t) ~keeper_name
    ~context_ratio ~strategy_names ~active_agent_count ~context_window
    ~is_local_model =
  let payload = `Assoc [
    ("keeper_name", `String keeper_name);
    ("context_ratio", `Float context_ratio);
    ("strategies", `List (List.map (fun s -> `String s) strategy_names));
    ("active_agent_count", `Int active_agent_count);
    ("context_window", `Int context_window);
    ("is_local_model", `Bool is_local_model);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  masc_publish
    (Agent_sdk.Event_bus.mk_event (Custom ("masc.harness.pre_compact", payload)))
