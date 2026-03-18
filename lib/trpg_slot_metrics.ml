(** TRPG Metrics Slot Implementation

    Metrics and analytics slot for TRPG sessions.
    Tracks event counts, turn statistics, actor activity, and session duration.

    @since 2.68.0
*)

open Yojson.Safe.Util

(** {1 Metrics State Types} *)

(** Event type counter *)
type event_counter = {
  room_created : int;
  room_started : int;
  phase_changed : int;
  turn_started : int;
  turn_action_proposed : int;
  turn_action_resolved : int;
  combat_attack : int;
  combat_defense : int;
  turn_timeout : int;
  keeper_unavailable : int;
  metric_updated : int;
  room_ended : int;
  session_outcome : int;
  dice_rolled : int;
  hp_changed : int;
  inventory_changed : int;
  flag_set : int;
  node_advanced : int;
  narration_posted : int;
  scene_transition : int;
  quest_update : int;
  world_event : int;
  session_started : int;
  party_selected : int;
  actor_spawned : int;
  actor_updated : int;
  actor_deleted : int;
  actor_claimed : int;
  actor_released : int;
  intervention_submitted : int;
  intervention_applied : int;
}

(** Empty counter *)
let empty_counter : event_counter = {
  room_created = 0;
  room_started = 0;
  phase_changed = 0;
  turn_started = 0;
  turn_action_proposed = 0;
  turn_action_resolved = 0;
  combat_attack = 0;
  combat_defense = 0;
  turn_timeout = 0;
  keeper_unavailable = 0;
  metric_updated = 0;
  room_ended = 0;
  session_outcome = 0;
  dice_rolled = 0;
  hp_changed = 0;
  inventory_changed = 0;
  flag_set = 0;
  node_advanced = 0;
  narration_posted = 0;
  scene_transition = 0;
  quest_update = 0;
  world_event = 0;
  session_started = 0;
  party_selected = 0;
  actor_spawned = 0;
  actor_updated = 0;
  actor_deleted = 0;
  actor_claimed = 0;
  actor_released = 0;
  intervention_submitted = 0;
  intervention_applied = 0;
}

(** Increment counter based on event type *)
let increment_counter (counter : event_counter) event_type =
  match event_type with
  | Trpg_engine_event.Room_created -> { counter with room_created = counter.room_created + 1 }
  | Room_started -> { counter with room_started = counter.room_started + 1 }
  | Phase_changed -> { counter with phase_changed = counter.phase_changed + 1 }
  | Turn_started -> { counter with turn_started = counter.turn_started + 1 }
  | Turn_action_proposed -> { counter with turn_action_proposed = counter.turn_action_proposed + 1 }
  | Turn_action_resolved -> { counter with turn_action_resolved = counter.turn_action_resolved + 1 }
  | Combat_attack -> { counter with combat_attack = counter.combat_attack + 1 }
  | Combat_defense -> { counter with combat_defense = counter.combat_defense + 1 }
  | Turn_timeout -> { counter with turn_timeout = counter.turn_timeout + 1 }
  | Keeper_unavailable -> { counter with keeper_unavailable = counter.keeper_unavailable + 1 }
  | Metric_updated -> { counter with metric_updated = counter.metric_updated + 1 }
  | Room_ended -> { counter with room_ended = counter.room_ended + 1 }
  | Session_outcome -> { counter with session_outcome = counter.session_outcome + 1 }
  | Dice_rolled -> { counter with dice_rolled = counter.dice_rolled + 1 }
  | Hp_changed -> { counter with hp_changed = counter.hp_changed + 1 }
  | Inventory_changed -> { counter with inventory_changed = counter.inventory_changed + 1 }
  | Flag_set -> { counter with flag_set = counter.flag_set + 1 }
  | Node_advanced -> { counter with node_advanced = counter.node_advanced + 1 }
  | Narration_posted -> { counter with narration_posted = counter.narration_posted + 1 }
  | Scene_transition -> { counter with scene_transition = counter.scene_transition + 1 }
  | Quest_update -> { counter with quest_update = counter.quest_update + 1 }
  | World_event -> { counter with world_event = counter.world_event + 1 }
  | Session_started -> { counter with session_started = counter.session_started + 1 }
  | Party_selected -> { counter with party_selected = counter.party_selected + 1 }
  | Actor_spawned -> { counter with actor_spawned = counter.actor_spawned + 1 }
  | Actor_updated -> { counter with actor_updated = counter.actor_updated + 1 }
  | Actor_deleted -> { counter with actor_deleted = counter.actor_deleted + 1 }
  | Actor_claimed -> { counter with actor_claimed = counter.actor_claimed + 1 }
  | Actor_released -> { counter with actor_released = counter.actor_released + 1 }
  | Intervention_submitted -> { counter with intervention_submitted = counter.intervention_submitted + 1 }
  | Intervention_applied -> { counter with intervention_applied = counter.intervention_applied + 1 }
  | Join_window_opened
  | Join_window_closed
  | Mid_join_requested
  | Mid_join_granted
  | Mid_join_rejected
  | Contribution_delta
  | Memory_signal
  | Bdi_updated
  | Evaluation_scored ->
      counter

(** Convert counter to Yojson.Safe.t *)
let counter_to_yojson (counter : event_counter) : Yojson.Safe.t =
  `Assoc [
    ("room_created", `Int counter.room_created);
    ("room_started", `Int counter.room_started);
    ("phase_changed", `Int counter.phase_changed);
    ("turn_started", `Int counter.turn_started);
    ("turn_action_proposed", `Int counter.turn_action_proposed);
    ("turn_action_resolved", `Int counter.turn_action_resolved);
    ("combat_attack", `Int counter.combat_attack);
    ("combat_defense", `Int counter.combat_defense);
    ("turn_timeout", `Int counter.turn_timeout);
    ("keeper_unavailable", `Int counter.keeper_unavailable);
    ("metric_updated", `Int counter.metric_updated);
    ("room_ended", `Int counter.room_ended);
    ("session_outcome", `Int counter.session_outcome);
    ("dice_rolled", `Int counter.dice_rolled);
    ("hp_changed", `Int counter.hp_changed);
    ("inventory_changed", `Int counter.inventory_changed);
    ("flag_set", `Int counter.flag_set);
    ("node_advanced", `Int counter.node_advanced);
    ("narration_posted", `Int counter.narration_posted);
    ("scene_transition", `Int counter.scene_transition);
    ("quest_update", `Int counter.quest_update);
    ("world_event", `Int counter.world_event);
    ("session_started", `Int counter.session_started);
    ("party_selected", `Int counter.party_selected);
    ("actor_spawned", `Int counter.actor_spawned);
    ("actor_updated", `Int counter.actor_updated);
    ("actor_deleted", `Int counter.actor_deleted);
    ("actor_claimed", `Int counter.actor_claimed);
    ("actor_released", `Int counter.actor_released);
    ("intervention_submitted", `Int counter.intervention_submitted);
    ("intervention_applied", `Int counter.intervention_applied);
  ]

(** Parse counter from Yojson.Safe.t *)
let counter_of_yojson (json : Yojson.Safe.t) : event_counter =
  let get_int key = match member key json with `Int i -> i | _ -> 0 in
  {
    room_created = get_int "room_created";
    room_started = get_int "room_started";
    phase_changed = get_int "phase_changed";
    turn_started = get_int "turn_started";
    turn_action_proposed = get_int "turn_action_proposed";
    turn_action_resolved = get_int "turn_action_resolved";
    combat_attack = get_int "combat_attack";
    combat_defense = get_int "combat_defense";
    turn_timeout = get_int "turn_timeout";
    keeper_unavailable = get_int "keeper_unavailable";
    metric_updated = get_int "metric_updated";
    room_ended = get_int "room_ended";
    session_outcome = get_int "session_outcome";
    dice_rolled = get_int "dice_rolled";
    hp_changed = get_int "hp_changed";
    inventory_changed = get_int "inventory_changed";
    flag_set = get_int "flag_set";
    node_advanced = get_int "node_advanced";
    narration_posted = get_int "narration_posted";
    scene_transition = get_int "scene_transition";
    quest_update = get_int "quest_update";
    world_event = get_int "world_event";
    session_started = get_int "session_started";
    party_selected = get_int "party_selected";
    actor_spawned = get_int "actor_spawned";
    actor_updated = get_int "actor_updated";
    actor_deleted = get_int "actor_deleted";
    actor_claimed = get_int "actor_claimed";
    actor_released = get_int "actor_released";
    intervention_submitted = get_int "intervention_submitted";
    intervention_applied = get_int "intervention_applied";
  }

(** Turn statistics *)
type turn_stat = {
  turn_number : int;
  event_count : int;
  actor_count : int;
  actions_proposed : int;
  actions_resolved : int;
  dice_rolled : int;
}

(** Empty turn stat *)
let empty_turn_stat ~turn_number = {
  turn_number;
  event_count = 0;
  actor_count = 0;
  actions_proposed = 0;
  actions_resolved = 0;
  dice_rolled = 0;
}

(** Convert turn stat to Yojson.Safe.t *)
let turn_stat_to_yojson (stat : turn_stat) : Yojson.Safe.t =
  `Assoc [
    ("turn_number", `Int stat.turn_number);
    ("event_count", `Int stat.event_count);
    ("actor_count", `Int stat.actor_count);
    ("actions_proposed", `Int stat.actions_proposed);
    ("actions_resolved", `Int stat.actions_resolved);
    ("dice_rolled", `Int stat.dice_rolled);
  ]

(** Parse turn stat from Yojson.Safe.t *)
let turn_stat_of_yojson (json : Yojson.Safe.t) : turn_stat =
  let get_int key = match member key json with `Int i -> i | _ -> 0 in
  {
    turn_number = get_int "turn_number";
    event_count = get_int "event_count";
    actor_count = get_int "actor_count";
    actions_proposed = get_int "actions_proposed";
    actions_resolved = get_int "actions_resolved";
    dice_rolled = get_int "dice_rolled";
  }

(** Actor activity record *)
type actor_activity = {
  actor_id : string;
  actions_taken : int;
  dice_rolled : int;
  interventions : int;
  hp_changes : int;
}

(** Empty actor activity *)
let empty_actor_activity ~actor_id = {
  actor_id;
  actions_taken = 0;
  dice_rolled = 0;
  interventions = 0;
  hp_changes = 0;
}

(** Update actor activity based on event *)
let update_actor_activity (activity : actor_activity) event_type =
  match event_type with
  | Trpg_engine_event.Turn_action_proposed -> { activity with actions_taken = activity.actions_taken + 1 }
  | Turn_action_resolved -> { activity with actions_taken = activity.actions_taken + 1 }
  | Combat_attack -> { activity with actions_taken = activity.actions_taken + 1 }
  | Combat_defense -> { activity with actions_taken = activity.actions_taken + 1 }
  | Dice_rolled -> { activity with dice_rolled = activity.dice_rolled + 1 }
  | Intervention_submitted -> { activity with interventions = activity.interventions + 1 }
  | Intervention_applied -> { activity with interventions = activity.interventions + 1 }
  | Hp_changed -> { activity with hp_changes = activity.hp_changes + 1 }
  | _ -> activity

(** Convert actor activity to Yojson.Safe.t *)
let actor_activity_to_yojson (activity : actor_activity) : Yojson.Safe.t =
  `Assoc [
    ("actor_id", `String activity.actor_id);
    ("actions_taken", `Int activity.actions_taken);
    ("dice_rolled", `Int activity.dice_rolled);
    ("interventions", `Int activity.interventions);
    ("hp_changes", `Int activity.hp_changes);
  ]

(** Parse actor activity from Yojson.Safe.t *)
let actor_activity_of_yojson (json : Yojson.Safe.t) : actor_activity =
  let actor_id = match member "actor_id" json with `String s -> s | _ -> "unknown" in
  let get_int key = match member key json with `Int i -> i | _ -> 0 in
  {
    actor_id;
    actions_taken = get_int "actions_taken";
    dice_rolled = get_int "dice_rolled";
    interventions = get_int "interventions";
    hp_changes = get_int "hp_changes";
  }

(** {1 Metrics Slot Implementation} *)

module Metrics_slot : Trpg_slot.TRPG_SLOT = struct
  (** Slot metadata *)
  let slot_info = {
    Trpg_slot.slot_id = "metrics";
    category = Trpg_slot.Metrics;
    version = "1.0.0";
    description = "TRPG session metrics and analytics tracking for event counts, turn stats, and actor activity over the session lifetime.";
  }

  (** Initialize metrics state *)
  let init_state ~config =
    (* Config can specify initial tracking options *)
    let start_time = match member "start_time" config with
      | `String s -> s
      | _ -> ""
    in
    `Assoc [
      ("event_counts", counter_to_yojson empty_counter);
      ("turn_stats", `List []);
      ("actor_activity", `Assoc []);
      ("session_start", `String start_time);
      ("session_end", `Null);
      ("total_events", `Int 0);
      ("total_turns", `Int 0);
    ]

  (** Empty state for fallback *)
  let empty_state = init_state ~config:(`Assoc [])

  (** Helper: Get current turn number from state *)
  let _get_current_turn state =
    match state with
    | `Assoc fields ->
        let get_field key = match List.assoc_opt key fields with
          | Some v -> v
          | None -> `Null
        in
        (match get_field "total_turns" with
         | `Int n -> n
         | _ -> 0)
    | _ -> 0

  (** Helper: Get or create turn stat *)
  let get_or_create_turn_stat turn_number state =
    match state with
    | `Assoc fields ->
        let get_field key = match List.assoc_opt key fields with
          | Some v -> v
          | None -> `Null
        in
        (match get_field "turn_stats" with
         | `List turn_stats ->
             (* Find existing stat for this turn *)
             let existing = List.find_opt (fun (json : Yojson.Safe.t) ->
               match json with
               | `Assoc stat_fields ->
                   (match List.assoc_opt "turn_number" stat_fields with
                    | Some (`Int n) -> n = turn_number
                    | _ -> false)
               | _ -> false
             ) turn_stats in
             (match existing with
              | Some stat -> turn_stat_of_yojson stat
              | None -> empty_turn_stat ~turn_number)
         | _ -> empty_turn_stat ~turn_number)
    | _ -> empty_turn_stat ~turn_number

  (** Helper: Update turn stat in list *)
  let update_turn_stat_in_list turn_stats (new_stat : turn_stat) =
    let new_json = turn_stat_to_yojson new_stat in
    let rec update (lst : Yojson.Safe.t list) : Yojson.Safe.t list =
      match lst with
      | [] -> [new_json]
      | json :: rest ->
          match json with
          | `Assoc stat_fields ->
              (match List.assoc_opt "turn_number" stat_fields with
               | Some (`Int n) when n = new_stat.turn_number -> new_json :: rest
               | _ -> json :: update rest)
          | _ -> json :: update rest
    in
    update turn_stats

  (** Apply event to metrics state *)
  let apply_event ~(state : Yojson.Safe.t) ~event : Yojson.Safe.t =
    match state with
    | `Assoc fields ->
        (* Helper to get value from fields list *)
        let get_field key = match List.assoc_opt key fields with
          | Some v -> v
          | None -> `Null
        in

        (* Update event counts *)
        let current_counter = match get_field "event_counts" with
          | `Assoc _ as json -> counter_of_yojson json
          | _ -> empty_counter
        in
        let updated_counter = increment_counter current_counter event.Trpg_engine_event.event_type in

        (* Update total events *)
        let total_events = match get_field "total_events" with
          | `Int n -> n + 1
          | _ -> 1
        in

        (* Track turn number for turn-related events *)
        let (total_turns, turn_stats) =
          match event.Trpg_engine_event.event_type with
          | Trpg_engine_event.Turn_started ->
              let current_turns = match get_field "total_turns" with `Int n -> n | _ -> 0 in
              let new_turn = current_turns + 1 in
              let existing_turn_stats = match get_field "turn_stats" with
                | `List stats -> stats
                | _ -> []
              in
              let new_stat = empty_turn_stat ~turn_number:new_turn in
              (new_turn, `List (existing_turn_stats @ [turn_stat_to_yojson new_stat]))
          | _ ->
              let current_turns = match get_field "total_turns" with `Int n -> n | _ -> 0 in
              let existing_turn_stats = match get_field "turn_stats" with
                | `List stats -> stats
                | _ -> []
              in
              (* Update current turn stat *)
              let turn_stat = get_or_create_turn_stat current_turns state in
              let updated_turn_stat = match event.Trpg_engine_event.event_type with
                | Trpg_engine_event.Turn_action_proposed ->
                    { turn_stat with actions_proposed = turn_stat.actions_proposed + 1 }
                | Turn_action_resolved ->
                    { turn_stat with actions_resolved = turn_stat.actions_resolved + 1 }
                | Dice_rolled ->
                    { turn_stat with dice_rolled = turn_stat.dice_rolled + 1 }
                | _ -> { turn_stat with event_count = turn_stat.event_count + 1 }
              in
              (current_turns, `List (update_turn_stat_in_list existing_turn_stats updated_turn_stat))
        in

        (* Update actor activity if actor_id is present *)
        let actor_activity = match event.Trpg_engine_event.actor_id with
          | Some actor_id when String.trim actor_id <> "" ->
              let existing_activities = match get_field "actor_activity" with
                | `Assoc acts -> acts
                | _ -> []
              in
              let current_activity = match List.assoc_opt actor_id existing_activities with
                | Some json -> actor_activity_of_yojson json
                | None -> empty_actor_activity ~actor_id
              in
              let updated_activity = update_actor_activity current_activity event.Trpg_engine_event.event_type in
              `Assoc ((actor_id, actor_activity_to_yojson updated_activity) :: List.remove_assoc actor_id existing_activities)
          | _ ->
              match get_field "actor_activity" with
              | `Assoc _ as json -> json
              | _ -> `Assoc []
        in

        (* Update session end time if room ended *)
        let session_end = match event.Trpg_engine_event.event_type with
          | Trpg_engine_event.Room_ended -> `String event.Trpg_engine_event.ts
          | _ -> match get_field "session_end" with `Null -> `Null | x -> x
        in

        (* Build updated state *)
        let session_start_value = match get_field "session_start" with `String s -> `String s | _ -> `Null in
        (`Assoc [
          ("event_counts", counter_to_yojson updated_counter);
          ("turn_stats", turn_stats);
          ("actor_activity", actor_activity);
          ("session_start", session_start_value);
          ("session_end", session_end);
          ("total_events", `Int total_events);
          ("total_turns", `Int total_turns);
        ] : Yojson.Safe.t)
    | _ -> empty_state

  (** Derive state for client consumption *)
  let derive_state ~state =
    (* Derive computed metrics *)
    match state with
    | `Assoc fields ->
        (* Helper to get field from Assoc list *)
        let get_field key = match List.assoc_opt key fields with
          | Some v -> v
          | None -> `Null
        in

        let total_events = match get_field "total_events" with `Int n -> n | _ -> 0 in
        let total_turns = match get_field "total_turns" with `Int n -> n | _ -> 0 in
        let counter = match get_field "event_counts" with
          | `Assoc _ as json -> counter_of_yojson json
          | _ -> empty_counter
        in
        let turn_stats = match get_field "turn_stats" with
          | `List stats -> List.map turn_stat_of_yojson stats
          | _ -> []
        in
        let actor_activity = match get_field "actor_activity" with
          | `Assoc acts -> List.map (fun (id, json) -> (id, actor_activity_of_yojson json)) acts
          | _ -> []
        in

        (* Calculate averages *)
        let avg_events_per_turn = if total_turns > 0 then float_of_int total_events /. float_of_int total_turns else 0.0 in
        let total_actions = counter.turn_action_proposed + counter.turn_action_resolved in
        let avg_actions_per_turn = if total_turns > 0 then float_of_int total_actions /. float_of_int total_turns else 0.0 in

        (* Calculate most active actor *)
        let most_active_actor = match List.sort (fun (_, a) (_, b) ->
          compare a.actions_taken b.actions_taken
        ) actor_activity with
          | (actor_id, _) :: _ -> actor_id
          | [] -> "none"
        in

        `Assoc [
          ("summary", `Assoc [
            ("total_events", `Int total_events);
            ("total_turns", `Int total_turns);
            ("avg_events_per_turn", `Float avg_events_per_turn);
            ("avg_actions_per_turn", `Float avg_actions_per_turn);
            ("most_active_actor", `String most_active_actor);
            ("total_dice_rolled", `Int counter.dice_rolled);
            ("total_narrations", `Int counter.narration_posted);
            ("total_interventions", `Int (counter.intervention_submitted + counter.intervention_applied));
          ]);
          ("event_counts", counter_to_yojson counter);
          ("turn_stats", `List (List.map turn_stat_to_yojson turn_stats));
          ("actor_activity", `Assoc (List.map (fun (id, act) -> (id, actor_activity_to_yojson act)) actor_activity));
          ("session_info", `Assoc [
            ("start", match get_field "session_start" with `String s -> `String s | _ -> `Null);
            ("end", match get_field "session_end" with `String s -> `String s | `Null -> `Null | _ -> `Null);
          ]);
        ]
    | _ -> `Assoc []
end

(** {1 Self-registration} *)

let () =
  Trpg_slot.Registry.register (module Metrics_slot : Trpg_slot.TRPG_SLOT)
