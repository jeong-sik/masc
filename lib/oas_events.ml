(** Agent_sdk Event_bus bridge for MASC runtime/social events.

    Publishes MASC coordination events (broadcasts, heartbeats, board posts)
    to the shared Event_bus using [Custom("masc:<type>", json)] format.
    This makes MASC orchestration events visible to Event_bus subscribers
    (traces, metrics, debugging tools).

    @since 2.90.0 *)

(** Publish a broadcast event to the shared Event_bus. *)
let publish_broadcast (bus : Agent_sdk.Event_bus.t) ~agent_name ~content =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("content", `String content);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:broadcast", payload)))

(** Publish a heartbeat event to the shared Event_bus. *)
let publish_heartbeat (bus : Agent_sdk.Event_bus.t) ~agent_name ~turn ~context_pct =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("turn", `Int turn);
    ("context_pct", `Float context_pct);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:heartbeat", payload)))

(** Publish a board post event to the shared Event_bus. *)
let publish_board_post (bus : Agent_sdk.Event_bus.t) ~agent_name ~post_id =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("post_id", `String post_id);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:board_post", payload)))

(** Publish a task state change event to the shared Event_bus. *)
let publish_task_transition (bus : Agent_sdk.Event_bus.t) ~agent_name ~task_id ~transition =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("transition", `String transition);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:task_transition", payload)))

(** Publish a heartbeat recovery event to the OAS Event_bus.
    Emitted when a previously timed-out agent re-activates. *)
let publish_heartbeat_recovered (bus : Agent_sdk.Event_bus.t) ~agent_name ~previous_timeout_s =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("previous_timeout_s", `Float previous_timeout_s);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:heartbeat_recovered", payload)))

(** {1 Autonomy Agent Lifecycle Events} *)

(** Publish an agent selection event (Thompson Sampling result).
    Emitted after [select_agents_with_thompson] in keeper_heartbeat. *)
let publish_agent_selected (bus : Agent_sdk.Event_bus.t) ~agent_name ~trigger
    ~thompson_score ~final_score =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("trigger", `String trigger);
    ("thompson_score", `Float thompson_score);
    ("final_score", `Float final_score);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:autonomy:agent_selected", payload)))

(** Publish an agent action decision event (MODEL decision result).
    Emitted after MODEL decides post/comment/upvote/skip. *)
let publish_agent_decision (bus : Agent_sdk.Event_bus.t) ~agent_name ~action
    ~trigger_reason =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("action", `String action);
    ("trigger_reason", `String trigger_reason);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:autonomy:agent_decision", payload)))

(** Publish an action execution result event.
    Emitted after an agent's action (post/comment/upvote) completes. *)
let publish_agent_action_executed (bus : Agent_sdk.Event_bus.t) ~agent_name
    ~action ~success =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("action", `String action);
    ("success", `Bool success);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:autonomy:agent_action_executed", payload)))

(** {1 Keeper Snapshot Events} *)

(** Publish a keeper snapshot event to the OAS Event_bus.
    Emitted alongside SSE broadcast in keeper_keepalive. *)
let publish_keeper_snapshot (bus : Agent_sdk.Event_bus.t) ~keeper_name
    ~generation ~context_ratio ~message_count =
  let payload = `Assoc [
    ("keeper_name", `String keeper_name);
    ("generation", `Int generation);
    ("context_ratio", `Float context_ratio);
    ("message_count", `Int message_count);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:keeper:snapshot", payload)))

(** {1 Keeper Lifecycle Events} *)

(** Publish a keeper keepalive lifecycle event.
    Event names: "started", "stopped", "crashed", "restarted", "dead". *)
let publish_keeper_lifecycle (bus : Agent_sdk.Event_bus.t) ~event ~keeper_name
    ~detail =
  let payload = `Assoc [
    ("event", `String event);
    ("keeper_name", `String keeper_name);
    ("detail", `String detail);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:keeper:lifecycle", payload)))

(** {1 Phase 4: Social Events} *)

(** Publish a trust score update between two agents. *)
let publish_trust_updated (bus : Agent_sdk.Event_bus.t) ~agent_a ~agent_b ~trust_score =
  let payload = `Assoc [
    ("agent_a", `String agent_a);
    ("agent_b", `String agent_b);
    ("trust_score", `Float trust_score);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:trust_updated", payload)))

(** Publish a reputation change event. *)
let publish_reputation_changed (bus : Agent_sdk.Event_bus.t) ~agent_name ~old_score ~new_score ~trend =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("old_score", `Float old_score);
    ("new_score", `Float new_score);
    ("trend", `String trend);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:reputation_changed", payload)))

(** Publish an institution episode event. *)
let publish_institution_episode (bus : Agent_sdk.Event_bus.t) ~episode_id ~event_type ~participants =
  let payload = `Assoc [
    ("episode_id", `String episode_id);
    ("event_type", `String event_type);
    ("participant_count", `Int (List.length participants));
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.mk_event (Custom ("masc:institution_episode", payload)))

(** {1 Harness Observability Events (#3165)} *)

(** Publish a verdict-recorded event.
    Emitted after [Eval_calibration.record_verdict] persists a verdict. *)
let publish_verdict_recorded (bus : Agent_sdk.Event_bus.t) ~agent_name ~task_id
    ~gate ~verdict =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("gate", `String gate);
    ("verdict", `String verdict);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:harness:verdict_recorded", payload)))

(** Publish a pre-compaction observation event.
    Emitted before [Context_compact_oas.compact] runs in keeper. *)
let publish_pre_compact (bus : Agent_sdk.Event_bus.t) ~keeper_name
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
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event (Custom ("masc:harness:pre_compact", payload)))
