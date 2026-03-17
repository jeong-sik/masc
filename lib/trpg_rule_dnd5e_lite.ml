(** Trpg_rule_dnd5e_lite — D&D 5e lite rule engine. *)

open Yojson.Safe.Util [@@warning "-33"]
include Trpg_rule_dnd5e_lite_core


let apply_combat_attack ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let attacker_id = resolve_actor_id payload event in
  let target_id = get_string_opt "target_id" payload in
  let raw_d20 = get_int_opt "raw_d20" payload |> Option.value ~default:10 in
  let base_damage = get_int_opt "base_damage" payload |> Option.value ~default:4 in
  let modifier = get_int_opt "modifier" payload |> Option.value ~default:0 in
  match attacker_id, target_id with
  | Some attacker, Some target ->
      let atk_stat = get_actor_stat state attacker "atk" 10 in
      let has_advantage = get_bool_opt "advantage" payload |> Option.value ~default:false in
      let has_disadvantage = get_bool_opt "disadvantage" payload |> Option.value ~default:false in
      let d20_2 = get_int_opt "d20_2" payload in
      let classification =
        match d20_2 with
        | Some d2 when has_advantage ->
            roll_with_advantage ~d20_1:raw_d20 ~d20_2:d2 ~stat:atk_stat ~modifier
        | Some d2 when has_disadvantage ->
            roll_with_disadvantage ~d20_1:raw_d20 ~d20_2:d2 ~stat:atk_stat ~modifier
        | _ ->
            roll_with_modifier ~raw_d20 ~stat:atk_stat ~modifier
      in
      let mult = damage_multiplier_of_tier classification.tier in
      let atk_bonus = stat_bonus atk_stat in
      let raw_damage =
        int_of_float (Float.round (float_of_int (base_damage + atk_bonus) *. mult))
      in
      let damage = max 0 raw_damage in
      let next_state =
        if damage > 0 then
          let s =
            update_party_actor state target (fun actor_json ->
                let old_hp =
                  actor_json |> member "hp" |> to_int_option |> Option.value ~default:0
                in
                let max_hp =
                  actor_json |> member "max_hp" |> to_int_option
                  |> Option.value ~default:old_hp
                in
                let new_hp = clamp_int 0 max_hp (old_hp - damage) in
                let alive = new_hp > 0 in
                let actor_fields = assoc_fields_or_empty actor_json in
                `Assoc
                  (actor_fields
                  |> assoc_put "hp" (`Int new_hp)
                  |> assoc_put "alive" (`Bool alive)))
          in
          let alive_after =
            s |> member "party" |> member target |> member "alive"
            |> to_bool_option
            |> Option.value ~default:true
          in
          if alive_after then s else update_actor_control s target None
        else state
      in
      let turn = state |> member "turn" |> to_int_option |> Option.value ~default:1 in
      let narration_entry =
        `Assoc
          [
            ("type", `String "combat_attack");
            ("turn", `Int turn);
            ("attacker", `String attacker);
            ("target", `String target);
            ("raw_d20", `Int raw_d20);
            ("tier", `String (roll_tier_to_string classification.tier));
            ("label", `String classification.label);
            ("damage", `Int damage);
          ]
      in
      append_to_list "narration_log" narration_entry next_state
  | _ -> append_to_list "narration_log" payload state

let apply_combat_defense ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let defender_id = resolve_actor_id payload event in
  let raw_d20 = get_int_opt "raw_d20" payload |> Option.value ~default:10 in
  let incoming_damage = get_int_opt "incoming_damage" payload |> Option.value ~default:0 in
  let modifier = get_int_opt "modifier" payload |> Option.value ~default:0 in
  match defender_id with
  | Some defender ->
      let def_stat = get_actor_stat state defender "def" 10 in
      let has_advantage = get_bool_opt "advantage" payload |> Option.value ~default:false in
      let has_disadvantage = get_bool_opt "disadvantage" payload |> Option.value ~default:false in
      let d20_2 = get_int_opt "d20_2" payload in
      let classification =
        match d20_2 with
        | Some d2 when has_advantage ->
            roll_with_advantage ~d20_1:raw_d20 ~d20_2:d2 ~stat:def_stat ~modifier
        | Some d2 when has_disadvantage ->
            roll_with_disadvantage ~d20_1:raw_d20 ~d20_2:d2 ~stat:def_stat ~modifier
        | _ ->
            roll_with_modifier ~raw_d20 ~stat:def_stat ~modifier
      in
      let mitigation = defense_mitigation_of_tier classification.tier in
      let mitigated =
        int_of_float (Float.round (float_of_int incoming_damage *. mitigation))
      in
      let actual_damage = max 0 (incoming_damage - mitigated) in
      let next_state =
        if actual_damage > 0 then
          let s =
            update_party_actor state defender (fun actor_json ->
                let old_hp =
                  actor_json |> member "hp" |> to_int_option |> Option.value ~default:0
                in
                let max_hp =
                  actor_json |> member "max_hp" |> to_int_option
                  |> Option.value ~default:old_hp
                in
                let new_hp = clamp_int 0 max_hp (old_hp - actual_damage) in
                let alive = new_hp > 0 in
                let actor_fields = assoc_fields_or_empty actor_json in
                `Assoc
                  (actor_fields
                  |> assoc_put "hp" (`Int new_hp)
                  |> assoc_put "alive" (`Bool alive)))
          in
          let alive_after =
            s |> member "party" |> member defender |> member "alive"
            |> to_bool_option
            |> Option.value ~default:true
          in
          if alive_after then s else update_actor_control s defender None
        else state
      in
      let turn = state |> member "turn" |> to_int_option |> Option.value ~default:1 in
      let narration_entry =
        `Assoc
          [
            ("type", `String "combat_defense");
            ("turn", `Int turn);
            ("defender", `String defender);
            ("raw_d20", `Int raw_d20);
            ("tier", `String (roll_tier_to_string classification.tier));
            ("label", `String classification.label);
            ("incoming_damage", `Int incoming_damage);
            ("mitigated", `Int mitigated);
            ("actual_damage", `Int actual_damage);
          ]
      in
      append_to_list "narration_log" narration_entry next_state
  | None -> append_to_list "narration_log" payload state

let apply_turn_timeout ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let turn = state |> member "turn" |> to_int_option |> Option.value ~default:1 in
  let actor_id =
    resolve_actor_id payload event |> Option.value ~default:"unknown"
  in
  let narration_entry =
    `Assoc
      [
        ("type", `String "turn_timeout");
        ("turn", `Int turn);
        ("actor_id", `String actor_id);
        ("message",
         `String
           (Printf.sprintf "[timeout] Turn %d timed out for %s" turn actor_id));
      ]
  in
  let state = append_to_list "narration_log" narration_entry state in
  match state with
  | `Assoc fields -> `Assoc (assoc_put "turn" (`Int (turn + 1)) fields)
  | _ -> state

let apply_keeper_unavailable ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let actor_id = resolve_actor_id payload event in
  match actor_id with
  | Some aid ->
      let state = update_actor_control state aid (Some "auto-pilot") in
      let turn = state |> member "turn" |> to_int_option |> Option.value ~default:1 in
      let narration_entry =
        `Assoc
          [
            ("type", `String "keeper_unavailable");
            ("turn", `Int turn);
            ("actor_id", `String aid);
            ("message",
             `String
               (Printf.sprintf "[auto-pilot] %s is now on auto-pilot" aid));
          ]
      in
      append_to_list "narration_log" narration_entry state
  | None -> state

let apply_world_event ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let effect_type =
    get_string_opt "effect_type" payload |> Option.value ~default:"unknown"
  in
  let damage = get_int_opt "damage" payload |> Option.value ~default:0 in
  let turn = state |> member "turn" |> to_int_option |> Option.value ~default:1 in
  let next_state =
    if damage <> 0 then begin
      let party_fields =
        match state with
        | `Assoc fields ->
            (match assoc_get "party" fields with
             | Some (`Assoc pf) -> pf
             | _ -> [])
        | _ -> []
      in
      let alive_actor_ids =
        List.filter_map
          (fun (actor_id, actor_json) ->
            let alive =
              get_bool_opt "alive" actor_json |> Option.value ~default:true
            in
            if alive then Some actor_id else None)
          party_fields
      in
      let s =
        List.fold_left
          (fun st actor_id ->
            update_party_actor st actor_id (fun aj ->
                let old_hp =
                  aj |> member "hp" |> to_int_option |> Option.value ~default:0
                in
                let max_hp =
                  aj |> member "max_hp" |> to_int_option
                  |> Option.value ~default:old_hp
                in
                let new_hp = clamp_int 0 max_hp (old_hp - damage) in
                let alive = new_hp > 0 in
                let actor_fields = assoc_fields_or_empty aj in
                `Assoc
                  (actor_fields
                  |> assoc_put "hp" (`Int new_hp)
                  |> assoc_put "alive" (`Bool alive))))
          state alive_actor_ids
      in
      List.fold_left
        (fun st actor_id ->
          let alive_after =
            st |> member "party" |> member actor_id |> member "alive"
            |> to_bool_option
            |> Option.value ~default:true
          in
          if alive_after then st else update_actor_control st actor_id None)
        s alive_actor_ids
    end
    else state
  in
  let narration_entry =
    `Assoc
      [
        ("type", `String "world_event");
        ("turn", `Int turn);
        ("effect_type", `String effect_type);
        ("damage", `Int damage);
      ]
  in
  append_to_list "narration_log" narration_entry next_state

let apply_session_started ~state ~event =
  let ts = event.Trpg_engine_event.ts in
  match state with
  | `Assoc fields ->
      `Assoc (assoc_put "session_started_at" (`String ts) fields)
  | _ -> state

let apply_event ~state ~(event : Trpg_engine_event.t) =
  (* Track last_event_ts for every event — enables staleness detection *)
  let state =
    match state with
    | `Assoc fields ->
        `Assoc (assoc_put "last_event_ts" (`String event.ts) fields)
    | _ -> state
  in
  match event.event_type with
  | Trpg_engine_event.Room_created ->
      let config = config_from_room_created_payload event.payload in
      let fields =
        init_state ~config
        |> assoc_fields_or_empty
      in
      `Assoc
        (fields
        |> assoc_put "status" (`String "lobby")
        |> assoc_put "phase" (`String "lobby")
        |> assoc_put "session_outcome" `Null)
  | Trpg_engine_event.Room_started ->
      (match state with
      | `Assoc fields ->
          `Assoc (fields
            |> assoc_put "status" (`String "active")
            |> assoc_put "phase" (`String "briefing")
            |> assoc_put "session_outcome" `Null
            |> assoc_put "dice_log" (`List [])
            |> assoc_put "narration_log" (`List [])
            |> assoc_put "actor_control" (`Assoc [])
            |> assoc_put "contribution_ledger" (`Assoc [])
            |> assoc_put
                 "join_gate"
                 (`Assoc
                   [
                     ("phase_open", `Bool true);
                     ("min_points", `Int 3);
                     ("window", `String "round_boundary_only");
                     ("last_opened_turn", `Int 1);
                     ("last_closed_turn", `Null);
                   ])
            |> assoc_put "current_node" `Null)
      | _ -> state)
  | Trpg_engine_event.Room_ended ->
      (match state with
      | `Assoc fields ->
          `Assoc (fields
            |> assoc_put "status" (`String "ended")
            |> assoc_put "phase" (`String "ended"))
      | _ -> state)
  | Trpg_engine_event.Session_outcome ->
      (match state with
      | `Assoc fields ->
          `Assoc
            (fields
            |> assoc_put "status" (`String "ended")
            |> assoc_put "phase" (`String "ended")
            |> assoc_put "session_outcome" event.payload)
      | _ -> state)
  | Trpg_engine_event.Turn_started ->
      let next_turn =
        event.payload |> member "turn" |> to_int_option |> Option.value ~default:1
      in
      (match state with
      | `Assoc fields ->
          `Assoc (fields
            |> assoc_put "turn" (`Int next_turn)
            |> assoc_put "phase" (`String "round"))
      | _ -> state)
      |> apply_turn_penalty_decay
  | Trpg_engine_event.Phase_changed ->
      let phase = get_string_opt "phase" event.payload |> Option.value ~default:"" in
      if phase = "" then state
      else
        (match state with
        | `Assoc fields -> `Assoc (assoc_put "phase" (`String phase) fields)
        | _ -> state)
  | Trpg_engine_event.Dice_rolled | Trpg_engine_event.Turn_action_resolved ->
      append_to_list "dice_log" event.payload state
  | Trpg_engine_event.Narration_posted ->
      append_to_list "narration_log" event.payload state
  | Trpg_engine_event.Turn_action_proposed ->
      append_to_list "narration_log"
        (normalize_player_action_for_narration ~state event.payload)
        state
  | Trpg_engine_event.Combat_attack -> apply_combat_attack ~state ~event
  | Trpg_engine_event.Combat_defense -> apply_combat_defense ~state ~event
  | Trpg_engine_event.Hp_changed -> apply_hp_changed ~state ~event
  | Trpg_engine_event.Inventory_changed -> apply_inventory_changed ~state ~event
  | Trpg_engine_event.Flag_set -> apply_flag_set ~state ~event
  | Trpg_engine_event.Node_advanced -> apply_node_advanced ~state ~event
  | Trpg_engine_event.Actor_spawned -> apply_actor_spawned ~state ~event
  | Trpg_engine_event.Actor_updated -> apply_actor_updated ~state ~event
  | Trpg_engine_event.Actor_deleted -> apply_actor_deleted ~state ~event
  | Trpg_engine_event.Actor_claimed -> apply_actor_claimed ~state ~event
  | Trpg_engine_event.Actor_released -> apply_actor_released ~state ~event
  | Trpg_engine_event.Join_window_opened ->
      apply_join_window_state ~state ~event ~phase_open:true
  | Trpg_engine_event.Join_window_closed ->
      apply_join_window_state ~state ~event ~phase_open:false
  | Trpg_engine_event.Contribution_delta ->
      apply_contribution_delta ~state ~event
  | Trpg_engine_event.Mid_join_requested
  | Trpg_engine_event.Mid_join_granted
  | Trpg_engine_event.Mid_join_rejected
  | Trpg_engine_event.Memory_signal ->
      append_to_list "narration_log" event.payload state
  | Trpg_engine_event.Scene_transition ->
      let payload = event.Trpg_engine_event.payload in
      let scene =
        get_string_opt "scene" payload |> Option.value ~default:"unknown"
      in
      let state = append_to_list "narration_log" payload state in
      (match state with
      | `Assoc fields ->
          let world =
            match assoc_get "world" fields with
            | Some (`Assoc w) -> `Assoc (assoc_put "current_scene" (`String scene) w)
            | _ -> `Assoc [ ("current_scene", `String scene) ]
          in
          `Assoc (assoc_put "world" world fields)
      | _ -> state)
  | Trpg_engine_event.Quest_update ->
      let payload = event.Trpg_engine_event.payload in
      let quest_info =
        get_string_opt "quest_info" payload |> Option.value ~default:""
      in
      let state = append_to_list "narration_log" payload state in
      (match state with
      | `Assoc fields ->
          let world =
            match assoc_get "world" fields with
            | Some (`Assoc w) -> `Assoc (assoc_put "quest_status" (`String quest_info) w)
            | _ -> `Assoc [ ("quest_status", `String quest_info) ]
          in
          `Assoc (assoc_put "world" world fields)
      | _ -> state)
  | Trpg_engine_event.Turn_timeout -> apply_turn_timeout ~state ~event
  | Trpg_engine_event.Keeper_unavailable -> apply_keeper_unavailable ~state ~event
  | Trpg_engine_event.World_event -> apply_world_event ~state ~event
  | Trpg_engine_event.Session_started -> apply_session_started ~state ~event
  | Trpg_engine_event.Metric_updated
  | Trpg_engine_event.Party_selected
  | Trpg_engine_event.Intervention_submitted
  | Trpg_engine_event.Intervention_applied
  | Trpg_engine_event.Bdi_updated
  | Trpg_engine_event.Evaluation_scored ->
      state

let derive_state ~state = state
