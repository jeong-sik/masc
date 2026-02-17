open Yojson.Safe.Util

type roll_tier =
  | Critical_fail
  | Fail
  | Partial
  | Success
  | Great
  | Miracle

type roll_classification = {
  tier : roll_tier;
  label : string;
  passed : bool;
}

let id = "dnd5e-lite"

let roll_tier_to_string = function
  | Critical_fail -> "critical_fail"
  | Fail -> "fail"
  | Partial -> "partial"
  | Success -> "success"
  | Great -> "great"
  | Miracle -> "miracle"

let stat_bonus stat_value = stat_value / 3

let classify_roll ~raw_d20 ~total =
  if raw_d20 = 1 then
    { tier = Critical_fail; label = "대참사"; passed = false }
  else if raw_d20 = 20 then
    { tier = Miracle; label = "기적"; passed = true }
  else if total <= 5 then
    { tier = Fail; label = "실패"; passed = false }
  else if total <= 10 then
    { tier = Partial; label = "부분 성공"; passed = true }
  else if total <= 15 then
    { tier = Success; label = "성공"; passed = true }
  else
    { tier = Great; label = "대성공"; passed = true }

let assoc_get key fields = List.assoc_opt key fields

let assoc_put key value fields =
  (key, value) :: List.remove_assoc key fields

let get_string_opt key json =
  match json |> member key with
  | `String s -> Some s
  | _ -> None

let get_int_opt key json =
  match json |> member key with
  | `Int i -> Some i
  | _ -> None

let get_bool_opt key json =
  match json |> member key with
  | `Bool b -> Some b
  | _ -> None

let assoc_fields_or_empty = function
  | `Assoc fields -> fields
  | _ -> []

let clamp_int low high value =
  if value < low then low
  else if value > high then high
  else value

let init_state ~config =
  let party = config |> member "party" in
  let world =
    match config |> member "world" with
    | `Assoc _ as w -> w
    | _ -> `Assoc [ ("story_flags", `List []) ]
  in
  `Assoc
    [
      ("status", `String "lobby");
      ("turn", `Int 1);
      ("current_node", `Null);
      ("party", if party = `Null then `Assoc [] else party);
      ("actor_control", `Assoc []);
      ("world", world);
      ("dice_log", `List []);
      ("narration_log", `List []);
    ]

let append_to_list key value state =
  match state with
  | `Assoc fields ->
      let prev =
        match assoc_get key fields with
        | Some (`List xs) -> xs
        | _ -> []
      in
      `Assoc (assoc_put key (`List (prev @ [ value ])) fields)
  | _ -> state

let update_party_actor state actor_id f =
  match state with
  | `Assoc fields ->
      let party_fields =
        match assoc_get "party" fields with
        | Some (`Assoc pf) -> pf
        | _ -> []
      in
      let actor_json = match List.assoc_opt actor_id party_fields with Some j -> j | None -> `Assoc [] in
      let next_actor = f actor_json in
      let next_party = `Assoc ((actor_id, next_actor) :: List.remove_assoc actor_id party_fields) in
      `Assoc (assoc_put "party" next_party fields)
  | _ -> state

let remove_party_actor state actor_id =
  match state with
  | `Assoc fields ->
      let party_fields =
        match assoc_get "party" fields with
        | Some (`Assoc pf) -> pf
        | _ -> []
      in
      let next_party = `Assoc (List.remove_assoc actor_id party_fields) in
      `Assoc (assoc_put "party" next_party fields)
  | _ -> state

let update_actor_control state actor_id keeper_name_opt =
  match state with
  | `Assoc fields ->
      let control_fields =
        match assoc_get "actor_control" fields with
        | Some (`Assoc xs) -> xs
        | _ -> []
      in
      let next_control =
        match keeper_name_opt with
        | Some keeper_name -> `Assoc (assoc_put actor_id (`String keeper_name) control_fields)
        | None -> `Assoc (List.remove_assoc actor_id control_fields)
      in
      `Assoc (assoc_put "actor_control" next_control fields)
  | _ -> state

let resolve_actor_id payload event =
  match get_string_opt "actor_id" payload with
  | Some id when String.trim id <> "" -> Some (String.trim id)
  | _ -> event.Trpg_engine_event.actor_id

let apply_hp_changed ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let actor_id = resolve_actor_id payload event in
  match actor_id with
  | None -> state
  | Some actor_id ->
      let next_state =
        update_party_actor state actor_id (fun actor_json ->
            let old_hp = actor_json |> member "hp" |> to_int_option |> Option.value ~default:0 in
            let max_hp =
              actor_json |> member "max_hp" |> to_int_option |> Option.value ~default:old_hp
            in
            let delta = get_int_opt "delta" payload |> Option.value ~default:0 in
            let computed_hp = clamp_int 0 max_hp (old_hp + delta) in
            let new_hp = get_int_opt "new_hp" payload |> Option.value ~default:computed_hp in
            let alive = get_bool_opt "alive" payload |> Option.value ~default:(new_hp > 0) in
            let actor_fields = assoc_fields_or_empty actor_json in
            `Assoc
              (actor_fields
              |> assoc_put "hp" (`Int new_hp)
              |> assoc_put "max_hp" (`Int max_hp)
              |> assoc_put "alive" (`Bool alive)))
      in
      let alive_after =
        next_state |> member "party" |> member actor_id |> member "alive"
        |> to_bool_option
        |> Option.value ~default:true
      in
      if alive_after then next_state
      else update_actor_control next_state actor_id None

let apply_inventory_changed ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let actor_id = resolve_actor_id payload event in
  match actor_id with
  | None -> state
  | Some actor_id ->
      let action = get_string_opt "action" payload |> Option.value ~default:"add" in
      let item = get_string_opt "item" payload |> Option.value ~default:"" in
      if item = "" then state
      else
        update_party_actor state actor_id (fun actor_json ->
            let actor_fields =
              match actor_json with
              | `Assoc fs -> fs
              | _ -> []
            in
            let inv =
              match List.assoc_opt "inventory" actor_fields with
              | Some (`List xs) -> xs
              | _ -> []
            in
            let updated =
              match action with
              | "remove" ->
                  inv
                  |> List.filter (fun x ->
                         match x with
                         | `String s -> not (String.equal s item)
                         | _ -> true)
              | _ -> inv @ [ `String item ]
            in
            `Assoc (assoc_put "inventory" (`List updated) actor_fields))

let apply_actor_spawned ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  match resolve_actor_id payload event with
  | None -> state
  | Some actor_id ->
      let actor_json =
        match payload |> member "actor" with
        | `Assoc _ as actor -> actor
        | _ -> `Assoc []
      in
      let actor_fields =
        actor_json
        |> assoc_fields_or_empty
        |> assoc_put "name"
             (`String
               (get_string_opt "name" actor_json
               |> Option.value ~default:actor_id))
        |> assoc_put "role"
             (`String
               (get_string_opt "role" actor_json
               |> Option.value ~default:"player"))
      in
      let max_hp =
        match List.assoc_opt "max_hp" actor_fields with
        | Some (`Int v) when v > 0 -> v
        | _ -> 10
      in
      let hp =
        match List.assoc_opt "hp" actor_fields with
        | Some (`Int v) -> clamp_int 0 max_hp v
        | _ -> max_hp
      in
      let alive =
        match List.assoc_opt "alive" actor_fields with
        | Some (`Bool b) -> b
        | _ -> hp > 0
      in
      update_party_actor state actor_id (fun _existing ->
          `Assoc
            (actor_fields
            |> assoc_put "max_hp" (`Int max_hp)
            |> assoc_put "hp" (`Int hp)
            |> assoc_put "alive" (`Bool alive)
            |> assoc_put "inventory"
                 (match List.assoc_opt "inventory" actor_fields with
                 | Some (`List _ as inv) -> inv
                 | _ -> `List [])))

let apply_actor_claimed ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let actor_id = resolve_actor_id payload event in
  let keeper_name =
    match get_string_opt "keeper_name" payload with
    | Some keeper when String.trim keeper <> "" -> Some (String.trim keeper)
    | _ -> (
        match get_string_opt "keeper" payload with
        | Some keeper when String.trim keeper <> "" -> Some (String.trim keeper)
        | _ -> None)
  in
  match actor_id, keeper_name with
  | Some actor_id, Some keeper_name ->
      update_actor_control state actor_id (Some keeper_name)
  | _ -> state

let apply_actor_released ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  match resolve_actor_id payload event with
  | Some actor_id -> update_actor_control state actor_id None
  | None -> state

let apply_actor_updated ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  match resolve_actor_id payload event with
  | None -> state
  | Some actor_id ->
      let patch_fields =
        match payload |> member "actor_patch" with
        | `Assoc fields -> fields
        | _ -> []
      in
      if patch_fields = [] then state
      else
        let next_state =
          update_party_actor state actor_id (fun actor_json ->
              let actor_fields = assoc_fields_or_empty actor_json in
              let merged_fields =
                List.fold_left
                  (fun acc (k, v) -> assoc_put k v acc)
                  actor_fields patch_fields
              in
              let max_hp =
                match List.assoc_opt "max_hp" merged_fields with
                | Some (`Int v) when v > 0 -> v
                | _ -> 10
              in
              let hp =
                match List.assoc_opt "hp" merged_fields with
                | Some (`Int v) -> clamp_int 0 max_hp v
                | _ -> max_hp
              in
              let alive =
                match List.assoc_opt "alive" merged_fields with
                | Some (`Bool b) -> b
                | _ -> hp > 0
              in
              `Assoc
                (merged_fields
                |> assoc_put "name"
                     (`String
                       (match List.assoc_opt "name" merged_fields with
                       | Some (`String s) when String.trim s <> "" -> s
                       | _ -> actor_id))
                |> assoc_put "role"
                     (`String
                       (match List.assoc_opt "role" merged_fields with
                       | Some (`String s) when String.trim s <> "" -> s
                       | _ -> "player"))
                |> assoc_put "max_hp" (`Int max_hp)
                |> assoc_put "hp" (`Int hp)
                |> assoc_put "alive" (`Bool alive)
                |> assoc_put "inventory"
                     (match List.assoc_opt "inventory" merged_fields with
                     | Some (`List _ as inv) -> inv
                     | _ -> `List [])))
        in
        let alive_after =
          next_state |> member "party" |> member actor_id |> member "alive"
          |> to_bool_option
          |> Option.value ~default:true
        in
        if alive_after then next_state
        else update_actor_control next_state actor_id None

let apply_actor_deleted ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  match resolve_actor_id payload event with
  | None -> state
  | Some actor_id ->
      let s = remove_party_actor state actor_id in
      update_actor_control s actor_id None

let apply_flag_set ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  let scope = get_string_opt "scope" payload |> Option.value ~default:"world" in
  let key = get_string_opt "key" payload |> Option.value ~default:"" in
  if key = "" then state
  else if scope = "world" then
    match state with
    | `Assoc fields ->
        let world_fields =
          match assoc_get "world" fields with
          | Some (`Assoc wf) -> wf
          | _ -> []
        in
        let story_flags =
          match List.assoc_opt "story_flags" world_fields with
          | Some (`List xs) -> xs
          | _ -> []
        in
        let already =
          List.exists
            (function `String s -> String.equal s key | _ -> false)
            story_flags
        in
        let next_flags = if already then story_flags else story_flags @ [ `String key ] in
        let next_world = `Assoc (assoc_put "story_flags" (`List next_flags) world_fields) in
        `Assoc (assoc_put "world" next_world fields)
    | _ -> state
  else state

let apply_node_advanced ~state ~event =
  let payload = event.Trpg_engine_event.payload in
  match state with
  | `Assoc fields ->
      let to_node = get_string_opt "to_node" payload |> Option.value ~default:"" in
      if to_node = "" then state
      else `Assoc (assoc_put "current_node" (`String to_node) fields)
  | _ -> state

let apply_event ~state ~(event : Trpg_engine_event.t) =
  match event.event_type with
  | Trpg_engine_event.Room_created ->
      (match state with
      | `Assoc fields -> `Assoc (assoc_put "status" (`String "lobby") fields)
      | _ -> state)
  | Trpg_engine_event.Room_started ->
      (match state with
      | `Assoc fields -> `Assoc (assoc_put "status" (`String "active") fields)
      | _ -> state)
  | Trpg_engine_event.Room_ended ->
      (match state with
      | `Assoc fields -> `Assoc (assoc_put "status" (`String "ended") fields)
      | _ -> state)
  | Trpg_engine_event.Turn_started ->
      let next_turn =
        event.payload |> member "turn" |> to_int_option |> Option.value ~default:1
      in
      (match state with
      | `Assoc fields -> `Assoc (assoc_put "turn" (`Int next_turn) fields)
      | _ -> state)
  | Trpg_engine_event.Dice_rolled | Trpg_engine_event.Turn_action_resolved ->
      append_to_list "dice_log" event.payload state
  | Trpg_engine_event.Narration_posted ->
      append_to_list "narration_log" event.payload state
  | Trpg_engine_event.Hp_changed -> apply_hp_changed ~state ~event
  | Trpg_engine_event.Inventory_changed -> apply_inventory_changed ~state ~event
  | Trpg_engine_event.Flag_set -> apply_flag_set ~state ~event
  | Trpg_engine_event.Node_advanced -> apply_node_advanced ~state ~event
  | Trpg_engine_event.Actor_spawned -> apply_actor_spawned ~state ~event
  | Trpg_engine_event.Actor_updated -> apply_actor_updated ~state ~event
  | Trpg_engine_event.Actor_deleted -> apply_actor_deleted ~state ~event
  | Trpg_engine_event.Actor_claimed -> apply_actor_claimed ~state ~event
  | Trpg_engine_event.Actor_released -> apply_actor_released ~state ~event
  | Trpg_engine_event.Phase_changed
  | Trpg_engine_event.Turn_action_proposed
  | Trpg_engine_event.Turn_timeout
  | Trpg_engine_event.Keeper_unavailable
  | Trpg_engine_event.Metric_updated
  | Trpg_engine_event.Scene_transition
  | Trpg_engine_event.Quest_update
  | Trpg_engine_event.World_event
  | Trpg_engine_event.Session_started
  | Trpg_engine_event.Party_selected
  | Trpg_engine_event.Intervention_submitted
  | Trpg_engine_event.Intervention_applied ->
      state

let derive_state ~state = state
