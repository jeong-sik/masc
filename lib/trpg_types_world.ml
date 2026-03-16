(** Trpg_types_world — string utilities, session outcome types, world contracts,
    end rules, and session outcome evaluation. *)

open Yojson.Safe.Util

let starts_with s prefix =
  let ls = String.length s and lp = String.length prefix in
  ls >= lp && String.sub s 0 lp = prefix

let find_substring s sub =
  let ls = String.length s and lp = String.length sub in
  if lp = 0 then Some 0
  else
    let rec loop i =
      if i + lp > ls then None
      else if String.sub s i lp = sub then Some i
      else loop (i + 1)
    in
    loop 0

let contains_substring s sub = Option.is_some (find_substring s sub)

type session_outcome =
  | Victory
  | Defeat
  | Draw

type outcome_source =
  | Outcome_source_flag
  | Outcome_source_dm_signal
  | Outcome_source_all_players_dead
  | Outcome_source_max_turn
  | Outcome_source_stagnation
  | Outcome_source_unknown

let string_of_session_outcome = function
  | Victory -> "victory"
  | Defeat -> "defeat"
  | Draw -> "draw"

let summary_of_session_outcome = function
  | Victory -> "Victory condition met."
  | Defeat -> "Defeat condition met."
  | Draw -> "Draw condition met."

let string_of_outcome_source = function
  | Outcome_source_flag -> "flag"
  | Outcome_source_dm_signal -> "dm_signal"
  | Outcome_source_all_players_dead -> "all_players_dead"
  | Outcome_source_max_turn -> "max_turn"
  | Outcome_source_stagnation -> "stagnation"
  | Outcome_source_unknown -> "unknown"

let outcome_source_of_reason reason =
  let trimmed = String.trim reason in
  if starts_with trimmed "flag:" then Outcome_source_flag
  else if starts_with trimmed "dm_signal:" then Outcome_source_dm_signal
  else if trimmed = "all_players_dead" then Outcome_source_all_players_dead
  else if trimmed = "max_turn_reached" then Outcome_source_max_turn
  else if trimmed = "stagnation" then Outcome_source_stagnation
  else Outcome_source_unknown

let outcome_source_from_payload_opt (payload : Yojson.Safe.t) : string option =
  match payload |> member "outcome_source" with
  | `String raw ->
      let source = String.trim raw in
      if source = "" then None else Some source
  | _ -> None

let outcome_source_from_payload (payload : Yojson.Safe.t) : string =
  match outcome_source_from_payload_opt payload with
  | Some source -> source
  | None ->
      let reason =
        match payload |> member "reason" with
        | `String raw -> raw
        | _ -> ""
      in
      string_of_outcome_source (outcome_source_of_reason reason)

let ensure_outcome_payload_source (payload : Yojson.Safe.t) : Yojson.Safe.t =
  let source = outcome_source_from_payload payload in
  match payload with
  | `Assoc fields ->
      `Assoc
        (("outcome_source", `String source)
        :: List.remove_assoc "outcome_source" fields)
  | _ -> payload

let stagnation_level_from_payload (payload : Yojson.Safe.t) : int =
  match payload |> member "stagnation_level" with
  | `Int n when n > 0 -> n
  | _ -> 0

let default_end_rules_local : Trpg_preset_store.end_rules =
  {
    max_turn = 40;
    defeat_if_all_players_dead = true;
    victory_flags = [ "outcome.victory"; "quest.main.completed"; "ending.victory" ];
    defeat_flags = [ "outcome.defeat"; "party.wiped"; "ending.defeat" ];
    draw_flags = [ "outcome.draw"; "ending.draw" ];
    allow_dm_end_signal = true;
  }

type world_contract = {
  id : string;
  title : string;
  description : string;
  required_flags : string list;
  forbidden_flags : string list;
  required_event_types : string list;
  required_event_types_any_of : string list list;
  banned_terms : string list;
}

type world_contract_catalog = {
  default_contract_id : string option;
  contracts : world_contract list;
}

let default_world_contract_catalog : world_contract_catalog =
  {
    default_contract_id = Some "open-runtime-v1";
    contracts =
      [
        {
          id = "open-runtime-v1";
          title = "Open Runtime Contract";
          description =
            "Baseline canon contract that keeps guardrails lightweight for sandbox runs.";
          required_flags = [];
          forbidden_flags = [];
          required_event_types = [];
          required_event_types_any_of =
            [ [ "scene.transition"; "quest.update"; "flag.set" ] ];
          banned_terms = [];
        };
        {
          id = "grimland-chronicle";
          title = "Grimland Chronicle Canon";
          description =
            "Keeps scarcity/political tone coherent for Grimland sessions.";
          required_flags = [ "scarcity.high"; "trust.public-low" ];
          forbidden_flags = [ "outcome.invalid"; "world.magic_unlimited" ];
          required_event_types = [];
          required_event_types_any_of =
            [
              [ "scene.transition"; "quest.update"; "flag.set" ];
              [ "combat.attack"; "combat.defense"; "dice.rolled" ];
            ];
          banned_terms =
            [ "spaceship"; "laser rifle"; "cyber implant"; "quantum drive" ];
        };
        {
          id = "emberfall-siege";
          title = "Emberfall Siege Canon";
          description =
            "Keeps siege pressure active for Emberfall sessions.";
          required_flags = [ "siege.active"; "morale.volatile" ];
          forbidden_flags = [ "peace.treaty.signed"; "outcome.invalid" ];
          required_event_types = [];
          required_event_types_any_of =
            [
              [ "scene.transition"; "quest.update"; "flag.set" ];
              [ "combat.attack"; "combat.defense"; "dice.rolled" ];
            ];
          banned_terms =
            [ "vacation"; "tourism festival"; "beach party"; "peace parade" ];
        };
      ];
  }

let world_contracts_path ~base_dir =
  Filename.concat base_dir "config/trpg/world_contracts.json"

let parse_world_contract_json (json : Yojson.Safe.t) :
    (world_contract, string) Stdlib.result =
  let ( let* ) = Result.bind in
  let string_field key =
    match json |> member key with
    | `String raw ->
        let value = String.trim raw in
        if value = "" then Error (Printf.sprintf "world contract %s is empty" key)
        else Ok value
    | _ -> Error (Printf.sprintf "world contract %s is required" key)
  in
  let string_list_field key =
    match json |> member key with
    | `List xs ->
        Ok
          (xs
          |> List.filter_map (function
               | `String raw ->
                   let value = String.trim raw in
                   if value = "" then None else Some value
               | _ -> None))
    | `Null -> Ok []
    | _ -> Error (Printf.sprintf "world contract %s must be string array" key)
  in
  let string_matrix_field key =
    match json |> member key with
    | `Null -> Ok []
    | `List rows ->
        let parse_row idx = function
          | `List xs ->
              let values =
                xs
                |> List.filter_map (function
                     | `String raw ->
                         let value = String.trim raw in
                         if value = "" then None else Some value
                     | _ -> None)
              in
              if values = [] then
                Error
                  (Printf.sprintf
                     "world contract %s[%d] must contain at least one string"
                     key idx)
              else Ok values
          | _ ->
              Error
                (Printf.sprintf
                   "world contract %s[%d] must be string array"
                   key idx)
        in
        let rec loop idx acc = function
          | [] -> Ok (List.rev acc)
          | row :: tl ->
              let* parsed = parse_row idx row in
              loop (idx + 1) (parsed :: acc) tl
        in
        loop 0 [] rows
    | _ -> Error (Printf.sprintf "world contract %s must be string[][]" key)
  in
  let* id = string_field "id" in
  let* title = string_field "title" in
  let description =
    match json |> member "description" with
    | `String raw -> String.trim raw
    | _ -> ""
  in
  let* required_flags = string_list_field "required_flags" in
  let* forbidden_flags = string_list_field "forbidden_flags" in
  let* required_event_types = string_list_field "required_event_types" in
  let* required_event_types_any_of =
    string_matrix_field "required_event_types_any_of"
  in
  let* banned_terms = string_list_field "banned_terms" in
  Ok
    {
      id;
      title;
      description;
      required_flags;
      forbidden_flags;
      required_event_types;
      required_event_types_any_of;
      banned_terms;
    }

let parse_world_contract_catalog_json (json : Yojson.Safe.t) :
    (world_contract_catalog, string) Stdlib.result =
  match json with
  | `Null -> Error "world contracts file not found"
  | _ ->
  let ( let* ) = Result.bind in
  let default_contract_id =
    match json |> member "default_contract_id" with
    | `String raw ->
        let value = String.trim raw in
        if value = "" then None else Some value
    | _ -> None
  in
  let* contracts =
    match json |> member "contracts" with
    | `List xs ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | item :: tl ->
              let* parsed = parse_world_contract_json item in
              loop (parsed :: acc) tl
        in
        loop [] xs
    | _ -> Error "world contracts file must contain contracts[]"
  in
  if contracts = [] then Error "world contracts file has empty contracts[]"
  else Ok { default_contract_id; contracts }

let load_world_contract_catalog ~(store : Trpg_store.t) : world_contract_catalog =
  match store.load_world_contracts () |> parse_world_contract_catalog_json with
  | Ok catalog -> catalog
  | Error _ -> default_world_contract_catalog

let find_world_contract (catalog : world_contract_catalog) ~id =
  catalog.contracts
  |> List.find_opt (fun (contract : world_contract) ->
         String.equal contract.id id)

let resolve_world_contract_for_session ~store ~world_preset_id
    ~world_contract_id_opt :
    (world_contract, string) Stdlib.result =
  let catalog = load_world_contract_catalog ~store in
  let requested_id =
    match world_contract_id_opt with
    | Some raw when String.trim raw <> "" -> Some (String.trim raw)
    | _ -> None
  in
  let default_id =
    match find_world_contract catalog ~id:world_preset_id with
    | Some _ -> Some world_preset_id
    | None -> (
        match catalog.default_contract_id with
        | Some raw when String.trim raw <> "" -> Some (String.trim raw)
        | _ -> (
            match catalog.contracts with
            | (first : world_contract) :: _ -> Some first.id
            | [] -> None))
  in
  let selected_id =
    match requested_id with Some _ -> requested_id | None -> default_id
  in
  match selected_id with
  | None -> Error "no world contract is available"
  | Some id -> (
      match find_world_contract catalog ~id with
      | Some contract -> Ok contract
      | None -> Error (Printf.sprintf "unknown world_contract_id: %s" id))

let world_contract_ref_to_yojson ~(contract : world_contract) ~strict :
    Yojson.Safe.t =
  `Assoc
    [
      ("id", `String contract.id);
      ("title", `String contract.title);
      ("description", `String contract.description);
      ("strict", `Bool strict);
    ]

let string_list_member_or_default json key default =
  match json |> member key with
  | `List xs ->
      let parsed =
        xs
        |> List.filter_map (function
             | `String s ->
                 let trimmed = String.trim s in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
      in
      if parsed = [] then default else parsed
  | _ -> default

let parse_end_rules_json (json : Yojson.Safe.t) : Trpg_preset_store.end_rules =
  {
    max_turn =
      (match json |> member "max_turn" with
      | `Int n when n > 0 -> n
      | _ -> default_end_rules_local.max_turn);
    defeat_if_all_players_dead =
      (match json |> member "defeat_if_all_players_dead" with
      | `Bool b -> b
      | _ -> default_end_rules_local.defeat_if_all_players_dead);
    victory_flags =
      string_list_member_or_default json "victory_flags"
        default_end_rules_local.victory_flags;
    defeat_flags =
      string_list_member_or_default json "defeat_flags"
        default_end_rules_local.defeat_flags;
    draw_flags =
      string_list_member_or_default json "draw_flags"
        default_end_rules_local.draw_flags;
    allow_dm_end_signal =
      (match json |> member "allow_dm_end_signal" with
      | `Bool b -> b
      | _ -> default_end_rules_local.allow_dm_end_signal);
  }

let extract_end_rules_from_room_created_payload (payload : Yojson.Safe.t) :
    Trpg_preset_store.end_rules option =
  match payload |> member "config" |> member "world" |> member "end_rules" with
  | `Assoc _ as end_rules_json -> Some (parse_end_rules_json end_rules_json)
  | _ -> None

let extract_world_preset_id_from_room_created_payload (payload : Yojson.Safe.t) :
    string option =
  match payload |> member "world_preset_id" with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let resolve_end_rules_for_room ~store ~(events : Trpg_engine_event.t list) :
    Trpg_preset_store.end_rules =
  match
    events
    |> List.fold_left
         (fun acc (ev : Trpg_engine_event.t) ->
           if ev.event_type = Trpg_engine_event.Room_created then Some ev else acc)
         None
  with
  | None -> default_end_rules_local
  | Some room_created -> (
      match extract_end_rules_from_room_created_payload room_created.payload with
      | Some rules -> rules
      | None -> (
          match
            extract_world_preset_id_from_room_created_payload room_created.payload
          with
          | Some world_preset_id -> (
              match store.Trpg_store.load_catalog () with
              | Ok catalog -> (
                  match
                    Trpg_preset_store.find_world_preset catalog ~id:world_preset_id
                  with
                  | Some preset -> preset.Trpg_preset_store.end_rules
                  | None -> default_end_rules_local)
              | Error _ -> default_end_rules_local)
          | None -> default_end_rules_local))

let story_flags_from_state (state : Yojson.Safe.t) : string list =
  match state |> member "world" |> member "story_flags" with
  | `List xs ->
      xs
      |> List.filter_map (function
           | `String s ->
               let trimmed = String.trim s in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let actor_is_player actor_id actor_json =
  if String.equal (String.trim actor_id) "dm" then false
  else
    let role =
      match actor_json |> member "role" with
      | `String s -> String.lowercase_ascii (String.trim s)
      | _ -> "player"
    in
    role <> "npc" && role <> "dm"

let actor_is_alive actor_json =
  match actor_json |> member "alive" with
  | `Bool b -> b
  | _ -> (
      match actor_json |> member "hp" with
      | `Int hp -> hp > 0
      | _ -> true)

let all_players_dead_in_state (state : Yojson.Safe.t) : bool =
  match state |> member "party" with
  | `Assoc actors ->
      let players = List.filter (fun (actor_id, actor_json) -> actor_is_player actor_id actor_json) actors in
      players <> [] && List.for_all (fun (_, actor_json) -> not (actor_is_alive actor_json)) players
  | _ -> false

let first_matching_flag ~story_flags candidates =
  candidates
  |> List.find_opt (fun candidate ->
         List.exists (fun flag -> String.equal (String.trim flag) (String.trim candidate)) story_flags)

let dm_signal_outcome reply_text =
  let upper = String.uppercase_ascii reply_text in
  if contains_substring upper "[VICTORY]" then Some (Victory, "dm_signal:[VICTORY]")
  else if contains_substring upper "[DEFEAT]" then
    Some (Defeat, "dm_signal:[DEFEAT]")
  else if contains_substring upper "[DRAW]" then Some (Draw, "dm_signal:[DRAW]")
  else if contains_substring upper "[END]" then Some (Draw, "dm_signal:[END]")
  else None

let evaluate_session_outcome ~end_rules ~max_turn_override
    ~(state : Yojson.Safe.t) ~dm_reply :
    (session_outcome * string) option =
  let story_flags = story_flags_from_state state in
  let draw_flag =
    first_matching_flag ~story_flags end_rules.Trpg_preset_store.draw_flags
  in
  let defeat_flag =
    first_matching_flag ~story_flags end_rules.Trpg_preset_store.defeat_flags
  in
  let victory_flag =
    first_matching_flag ~story_flags end_rules.Trpg_preset_store.victory_flags
  in
  let all_players_dead =
    end_rules.Trpg_preset_store.defeat_if_all_players_dead
    && all_players_dead_in_state state
  in
  let effective_max_turn =
    match max_turn_override with
    | Some n when n > 0 -> min end_rules.Trpg_preset_store.max_turn n
    | _ -> end_rules.Trpg_preset_store.max_turn
  in
  let max_turn_reached =
    let turn =
      match state |> member "turn" with
      | `Int n -> n
      | _ -> 0
    in
    turn >= effective_max_turn
  in
  match draw_flag with
  | Some flag -> Some (Draw, "flag:" ^ flag)
  | None -> (
      match defeat_flag with
      | Some flag -> Some (Defeat, "flag:" ^ flag)
      | None -> (
          match victory_flag with
          | Some flag -> Some (Victory, "flag:" ^ flag)
          | None ->
              if all_players_dead then
                Some (Defeat, "all_players_dead")
              else (
                match (end_rules.Trpg_preset_store.allow_dm_end_signal, dm_reply) with
                | true, Some reply -> (
                    match dm_signal_outcome reply with
                    | Some outcome -> Some outcome
                    | None ->
                        if max_turn_reached then Some (Draw, "max_turn_reached")
                        else None)
                | _ ->
                    if max_turn_reached then Some (Draw, "max_turn_reached")
                    else None)))

