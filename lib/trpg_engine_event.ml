type event_type =
  | Room_created
  | Room_started
  | Phase_changed
  | Turn_started
  | Turn_action_proposed
  | Turn_action_resolved
  | Combat_attack
  | Combat_defense
  | Turn_timeout
  | Keeper_unavailable
  | Metric_updated
  | Room_ended
  | Session_outcome
  | Dice_rolled
  | Hp_changed
  | Inventory_changed
  | Flag_set
  | Node_advanced
  | Narration_posted
  | Scene_transition
  | Quest_update
  | World_event
  | Session_started
  | Party_selected
  | Actor_spawned
  | Actor_updated
  | Actor_deleted
  | Actor_claimed
  | Actor_released
  | Join_window_opened
  | Join_window_closed
  | Mid_join_requested
  | Mid_join_granted
  | Mid_join_rejected
  | Contribution_delta
  | Memory_signal
  | Intervention_submitted
  | Intervention_applied
  | Bdi_updated
  | Evaluation_scored

type t = {
  seq : int;
  room_id : string;
  ts : string;
  event_type : event_type;
  actor_id : string option;
  payload : Yojson.Safe.t;
}

let string_of_event_type = function
  | Room_created -> "room.created"
  | Room_started -> "room.started"
  | Phase_changed -> "phase.changed"
  | Turn_started -> "turn.started"
  | Turn_action_proposed -> "turn.action.proposed"
  | Turn_action_resolved -> "turn.action.resolved"
  | Combat_attack -> "combat.attack"
  | Combat_defense -> "combat.defense"
  | Turn_timeout -> "turn.timeout"
  | Keeper_unavailable -> "keeper.unavailable"
  | Metric_updated -> "metric.updated"
  | Room_ended -> "room.ended"
  | Session_outcome -> "session.outcome"
  | Dice_rolled -> "dice.rolled"
  | Hp_changed -> "hp.changed"
  | Inventory_changed -> "inventory.changed"
  | Flag_set -> "flag.set"
  | Node_advanced -> "node.advanced"
  | Narration_posted -> "narration.posted"
  | Scene_transition -> "scene.transition"
  | Quest_update -> "quest.update"
  | World_event -> "world.event"
  | Session_started -> "session.started"
  | Party_selected -> "party.selected"
  | Actor_spawned -> "actor.spawned"
  | Actor_updated -> "actor.updated"
  | Actor_deleted -> "actor.deleted"
  | Actor_claimed -> "actor.claimed"
  | Actor_released -> "actor.released"
  | Join_window_opened -> "join.window.opened"
  | Join_window_closed -> "join.window.closed"
  | Mid_join_requested -> "mid.join.requested"
  | Mid_join_granted -> "mid.join.granted"
  | Mid_join_rejected -> "mid.join.rejected"
  | Contribution_delta -> "contribution.delta"
  | Memory_signal -> "memory.signal"
  | Intervention_submitted -> "intervention.submitted"
  | Intervention_applied -> "intervention.applied"
  | Bdi_updated -> "bdi.updated"
  | Evaluation_scored -> "evaluation.scored"

let event_type_of_string = function
  | "room.created" -> Ok Room_created
  | "room.started" -> Ok Room_started
  | "phase.changed" -> Ok Phase_changed
  | "turn.started" -> Ok Turn_started
  | "turn.action.proposed" -> Ok Turn_action_proposed
  | "turn.action.resolved" -> Ok Turn_action_resolved
  | "combat.attack" -> Ok Combat_attack
  | "combat.defense" -> Ok Combat_defense
  | "turn.timeout" -> Ok Turn_timeout
  | "keeper.unavailable" -> Ok Keeper_unavailable
  | "metric.updated" -> Ok Metric_updated
  | "room.ended" -> Ok Room_ended
  | "session.outcome" -> Ok Session_outcome
  | "dice.rolled" -> Ok Dice_rolled
  | "hp.changed" -> Ok Hp_changed
  | "inventory.changed" -> Ok Inventory_changed
  | "flag.set" -> Ok Flag_set
  | "node.advanced" -> Ok Node_advanced
  | "narration.posted" -> Ok Narration_posted
  | "scene.transition" -> Ok Scene_transition
  | "quest.update" -> Ok Quest_update
  | "world.event" -> Ok World_event
  | "session.started" -> Ok Session_started
  | "party.selected" -> Ok Party_selected
  | "actor.spawned" -> Ok Actor_spawned
  | "actor.updated" -> Ok Actor_updated
  | "actor.deleted" -> Ok Actor_deleted
  | "actor.claimed" -> Ok Actor_claimed
  | "actor.released" -> Ok Actor_released
  | "join.window.opened" -> Ok Join_window_opened
  | "join.window.closed" -> Ok Join_window_closed
  | "mid.join.requested" -> Ok Mid_join_requested
  | "mid.join.granted" -> Ok Mid_join_granted
  | "mid.join.rejected" -> Ok Mid_join_rejected
  | "contribution.delta" -> Ok Contribution_delta
  | "memory.signal" -> Ok Memory_signal
  | "intervention.submitted" -> Ok Intervention_submitted
  | "intervention.applied" -> Ok Intervention_applied
  | "bdi.updated" -> Ok Bdi_updated
  | "evaluation.scored" -> Ok Evaluation_scored
  | s -> Error (Printf.sprintf "unknown event_type: %s" s)

let make ~seq ~room_id ~ts ~event_type ?actor_id ~payload () =
  { seq; room_id; ts; event_type; actor_id; payload }

let to_yojson (e : t) : Yojson.Safe.t =
  `Assoc
    [
      ("seq", `Int e.seq);
      ("room_id", `String e.room_id);
      ("ts", `String e.ts);
      ("type", `String (string_of_event_type e.event_type));
      ("actor_id", match e.actor_id with Some x -> `String x | None -> `Null);
      ("payload", e.payload);
    ]

let of_yojson (json : Yojson.Safe.t) : (t, string) result =
  let module U = Yojson.Safe.Util in
  try
    let seq = json |> U.member "seq" |> U.to_int in
    let room_id = json |> U.member "room_id" |> U.to_string in
    let ts = json |> U.member "ts" |> U.to_string in
    let event_type_s = json |> U.member "type" |> U.to_string in
    let actor_id = json |> U.member "actor_id" |> U.to_string_option in
    let payload = json |> U.member "payload" in
    match event_type_of_string event_type_s with
    | Ok event_type ->
        Ok
          {
            seq;
            room_id;
            ts;
            event_type;
            actor_id;
            payload;
          }
    | Error e -> Error e
  with e -> Error (Printexc.to_string e)
