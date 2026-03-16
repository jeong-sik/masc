(** OAS Event_bus bridge for MASC social events.

    Publishes MASC coordination events (broadcasts, heartbeats, board posts)
    to the OAS Event_bus using [Custom("masc:<type>", json)] format.
    This makes MASC orchestration events visible to OAS subscribers
    (traces, metrics, debugging tools).

    @since 2.90.0 *)

(** Publish a broadcast event to the OAS Event_bus. *)
let publish_broadcast (bus : Agent_sdk.Event_bus.t) ~agent_name ~content =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("content", `String content);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:broadcast", payload))

(** Publish a heartbeat event to the OAS Event_bus. *)
let publish_heartbeat (bus : Agent_sdk.Event_bus.t) ~agent_name ~turn ~context_pct =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("turn", `Int turn);
    ("context_pct", `Float context_pct);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:heartbeat", payload))

(** Publish a board post event to the OAS Event_bus. *)
let publish_board_post (bus : Agent_sdk.Event_bus.t) ~agent_name ~post_id =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("post_id", `String post_id);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:board_post", payload))

(** Publish a task state change event to the OAS Event_bus. *)
let publish_task_transition (bus : Agent_sdk.Event_bus.t) ~agent_name ~task_id ~transition =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("task_id", `String task_id);
    ("transition", `String transition);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:task_transition", payload))

(** Publish a heartbeat recovery event to the OAS Event_bus.
    Emitted when a previously timed-out agent re-activates. *)
let publish_heartbeat_recovered (bus : Agent_sdk.Event_bus.t) ~agent_name ~previous_timeout_s =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("previous_timeout_s", `Float previous_timeout_s);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:heartbeat_recovered", payload))

(** {1 Phase 4: Social Events} *)

(** Publish a trust score update between two agents. *)
let publish_trust_updated (bus : Agent_sdk.Event_bus.t) ~agent_a ~agent_b ~trust_score =
  let payload = `Assoc [
    ("agent_a", `String agent_a);
    ("agent_b", `String agent_b);
    ("trust_score", `Float trust_score);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:trust_updated", payload))

(** Publish a reputation change event. *)
let publish_reputation_changed (bus : Agent_sdk.Event_bus.t) ~agent_name ~old_score ~new_score ~trend =
  let payload = `Assoc [
    ("agent_name", `String agent_name);
    ("old_score", `Float old_score);
    ("new_score", `Float new_score);
    ("trend", `String trend);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:reputation_changed", payload))

(** Publish an institution episode event. *)
let publish_institution_episode (bus : Agent_sdk.Event_bus.t) ~episode_id ~event_type ~participants =
  let payload = `Assoc [
    ("episode_id", `String episode_id);
    ("event_type", `String event_type);
    ("participant_count", `Int (List.length participants));
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  Agent_sdk.Event_bus.publish bus (Agent_sdk.Event_bus.Custom ("masc:institution_episode", payload))
