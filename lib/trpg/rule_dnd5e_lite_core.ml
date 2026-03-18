(** Rule_dnd5e_lite core — types, constants, helpers, basic event handlers. *)

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

let roll_with_modifier ~raw_d20 ~stat ~modifier =
  let bonus = stat_bonus stat in
  let total = raw_d20 + bonus + modifier in
  classify_roll ~raw_d20 ~total

let roll_with_advantage ~d20_1 ~d20_2 ~stat ~modifier =
  let raw_d20 = max d20_1 d20_2 in
  roll_with_modifier ~raw_d20 ~stat ~modifier

let roll_with_disadvantage ~d20_1 ~d20_2 ~stat ~modifier =
  let raw_d20 = min d20_1 d20_2 in
  roll_with_modifier ~raw_d20 ~stat ~modifier

let damage_multiplier_of_tier = function
  | Miracle -> 2.0
  | Great -> 1.5
  | Success -> 1.0
  | Partial -> 0.5
  | Fail | Critical_fail -> 0.0

let defense_mitigation_of_tier = function
  | Miracle -> 1.0
  | Great -> 0.75
  | Success -> 0.5
  | Partial -> 0.25
  | Fail | Critical_fail -> 0.0

let assoc_get key fields = List.assoc_opt key fields

let assoc_put key value fields =
  (key, value) :: List.remove_assoc key fields

let get_string_opt = Util.json_string_opt
let get_int_opt = Util.json_int_opt
let get_bool_opt = Util.json_bool_opt

let assoc_fields_or_empty = function
  | `Assoc fields -> fields
  | _ -> []

let clamp_int low high value =
  if value < low then low
  else if value > high then high
  else value

let get_actor_stat state actor_id stat_key default_val =
  match state with
  | `Assoc fields ->
      (match assoc_get "party" fields with
       | Some (`Assoc pf) ->
           (match List.assoc_opt actor_id pf with
            | Some actor_json ->
                get_int_opt stat_key actor_json |> Option.value ~default:default_val
            | None -> default_val)
       | _ -> default_val)
  | _ -> default_val

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
      ("phase", `String "lobby");
      ("turn", `Int 1);
      ("last_event_ts", `Null);
      ("current_node", `Null);
      ("party", if party = `Null then `Assoc [] else party);
      ("actor_control", `Assoc []);
      ("world", world);
      ("dice_log", `List []);
      ("narration_log", `List []);
      ( "join_gate",
        `Assoc
          [
            ("phase_open", `Bool true);
            ("min_points", `Int 3);
            ("window", `String "round_boundary_only");
            ("last_opened_turn", `Int 1);
            ("last_closed_turn", `Null);
          ] );
      ("contribution_ledger", `Assoc []);
    ]

let config_from_room_created_payload payload =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt "config" fields with
      | Some (`Assoc _ as cfg) -> cfg
      | Some _ -> `Assoc []
      | None ->
          if List.mem_assoc "party" fields || List.mem_assoc "world" fields then
            payload
          else
            `Assoc [])
  | _ -> `Assoc []

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
  | _ -> event.Engine_event.actor_id

let apply_hp_changed ~state ~event =
  let payload = event.Engine_event.payload in
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
  let payload = event.Engine_event.payload in
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
  let payload = event.Engine_event.payload in
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
  let payload = event.Engine_event.payload in
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
  let payload = event.Engine_event.payload in
  match resolve_actor_id payload event with
  | Some actor_id -> update_actor_control state actor_id None
  | None -> state

let apply_actor_updated ~state ~event =
  let payload = event.Engine_event.payload in
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
  let payload = event.Engine_event.payload in
  match resolve_actor_id payload event with
  | None -> state
  | Some actor_id ->
      let s = remove_party_actor state actor_id in
      update_actor_control s actor_id None

let apply_flag_set ~state ~event =
  let payload = event.Engine_event.payload in
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
  let payload = event.Engine_event.payload in
  match state with
  | `Assoc fields ->
      let to_node = get_string_opt "to_node" payload |> Option.value ~default:"" in
      if to_node = "" then state
      else `Assoc (assoc_put "current_node" (`String to_node) fields)
  | _ -> state

let apply_join_window_state ~state ~event ~phase_open =
  match state with
  | `Assoc fields ->
      let join_gate_fields =
        match assoc_get "join_gate" fields with
        | Some (`Assoc xs) -> xs
        | _ -> []
      in
      let current_turn =
        state |> member "turn" |> to_int_option |> Option.value ~default:1
      in
      let turn_value =
        get_int_opt "turn" event.Engine_event.payload
        |> Option.value ~default:current_turn
      in
      let min_points =
        match List.assoc_opt "min_points" join_gate_fields with
        | Some (`Int v) -> v
        | _ -> 3
      in
      let updated_fields =
        join_gate_fields
        |> assoc_put "phase_open" (`Bool phase_open)
        |> assoc_put "min_points" (`Int min_points)
        |> assoc_put "window" (`String "round_boundary_only")
        |> assoc_put
             (if phase_open then "last_opened_turn" else "last_closed_turn")
             (`Int turn_value)
      in
      `Assoc (assoc_put "join_gate" (`Assoc updated_fields) fields)
  | _ -> state

let apply_contribution_delta ~state ~event =
  let payload = event.Engine_event.payload in
  let actor_id =
    match get_string_opt "actor_id" payload with
    | Some actor when String.trim actor <> "" -> String.trim actor
    | _ ->
        Option.value ~default:"" event.Engine_event.actor_id
        |> String.trim
  in
  if actor_id = "" then state
  else
    match state with
    | `Assoc fields ->
        let ledger_fields =
          match assoc_get "contribution_ledger" fields with
          | Some (`Assoc xs) -> xs
          | _ -> []
        in
        let actor_fields =
          match List.assoc_opt actor_id ledger_fields with
          | Some (`Assoc xs) -> xs
          | _ -> []
        in
        let prev_score =
          match List.assoc_opt "score" actor_fields with
          | Some (`Int v) -> v
          | _ -> 0
        in
        let delta = get_int_opt "delta" payload |> Option.value ~default:0 in
        let score_after =
          get_int_opt "score_after" payload |> Option.value ~default:(prev_score + delta)
        in
        let reason = get_string_opt "reason" payload |> Option.value ~default:"" in
        let turn_value =
          get_int_opt "turn" payload
          |> Option.value
               ~default:(state |> member "turn" |> to_int_option |> Option.value ~default:1)
        in
        let reasons =
          match List.assoc_opt "reasons" actor_fields with
          | Some (`List xs) -> xs
          | _ -> []
        in
        let reasons =
          if String.trim reason = "" then reasons
          else
            let next = reasons @ [ `String reason ] in
            let len = List.length next in
            if len <= 8 then next else
              let rec drop n xs =
                if n <= 0 then xs
                else
                  match xs with
                  | [] -> []
                  | _ :: tl -> drop (n - 1) tl
              in
              drop (len - 8) next
        in
        let actor_entry =
          actor_fields
          |> assoc_put "score" (`Int score_after)
          |> assoc_put "last_delta" (`Int delta)
          |> assoc_put "last_turn" (`Int turn_value)
          |> assoc_put
               "last_reason"
               (if String.trim reason = "" then `Null else `String reason)
          |> assoc_put "reasons" (`List reasons)
        in
        let ledger =
          `Assoc ((actor_id, `Assoc actor_entry) :: List.remove_assoc actor_id ledger_fields)
        in
        `Assoc (assoc_put "contribution_ledger" ledger fields)
    | _ -> state

let apply_turn_penalty_decay state =
  match state with
  | `Assoc fields ->
      let party_fields =
        match assoc_get "party" fields with
        | Some (`Assoc xs) -> xs
        | _ -> []
      in
      let next_party =
        party_fields
        |> List.map (fun (actor_id, actor_json) ->
               let actor_fields = assoc_fields_or_empty actor_json in
               let turns_left =
                 match List.assoc_opt "late_join_penalty_turns" actor_fields with
                 | Some (`Int v) -> max 0 v
                 | _ -> 0
               in
               if turns_left <= 0 then (actor_id, actor_json)
               else
                 let remaining = max 0 (turns_left - 1) in
                 let next_fields =
                   actor_fields
                   |> assoc_put "late_join_penalty_turns" (`Int remaining)
                   |> assoc_put "late_join_penalty" (`Bool (remaining > 0))
                 in
                 (actor_id, `Assoc next_fields))
      in
      `Assoc (assoc_put "party" (`Assoc next_party) fields)
  | _ -> state

let normalize_player_action_for_narration ~state payload =
  let fallback_turn = state |> member "turn" |> to_int_option |> Option.value ~default:1 in
  let phase = get_string_opt "phase" payload |> Option.value ~default:"round" in
  let turn = get_int_opt "turn" payload |> Option.value ~default:fallback_turn in
  let actor_id =
    get_string_opt "actor_id" payload |> Option.value ~default:"unknown"
  in
  let keeper = get_string_opt "keeper" payload |> Option.value ~default:"" in
  let reply =
    get_string_opt "proposed_action" payload
    |> Option.value ~default:(get_string_opt "reply" payload |> Option.value ~default:"")
  in
  `Assoc
    [
      ("phase", `String phase);
      ("turn", `Int turn);
      ("role", `String "player");
      ("actor_id", `String actor_id);
      ("keeper", `String keeper);
      ("reply", `String reply);
    ]
