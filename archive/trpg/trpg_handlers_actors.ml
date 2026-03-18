(** Trpg_handlers_actors — actor CRUD: spawn, update, delete, match, claim, release. *)

include Trpg_round
open Yojson.Safe.Util

let actor_payload_from_spawn_args args ~actor_id =
  let ( let* ) = Result.bind in
  let* role_opt = get_optional_string args "role" in
  let role = Option.value ~default:"player" role_opt |> String.lowercase_ascii in
  let* () = validate_actor_role role in
  let* name_opt = get_optional_string args "name" in
  let* archetype_opt = get_optional_string args "archetype" in
  let* persona_opt = get_optional_string args "persona" in
  let* portrait_opt = get_optional_string args "portrait" in
  let* background_opt = get_optional_string args "background" in
  let* stats_opt = get_optional_object args "stats" in
  let* hp_opt = get_optional_int args "hp" in
  let* max_hp_opt = get_optional_int args "max_hp" in
  let* alive = get_optional_bool args "alive" ~default:true in
  let* traits = get_optional_string_list args "traits" in
  let* skills = get_optional_string_list args "skills" in
  let* inventory = get_optional_string_list args "inventory" in
  let max_hp = Option.value ~default:10 max_hp_opt in
  if max_hp <= 0 then Error "max_hp must be > 0"
  else
    let hp = Option.value ~default:max_hp hp_opt in
    if hp < 0 then Error "hp must be >= 0"
    else
      let hp = min hp max_hp in
      let actor_json =
        `Assoc
          [
            ("name", `String (Option.value ~default:actor_id name_opt));
            ("role", `String role);
            ("archetype", Option.fold ~none:`Null ~some:(fun v -> `String v) archetype_opt);
            ("persona", Option.fold ~none:`Null ~some:(fun v -> `String v) persona_opt);
            ("portrait", Option.fold ~none:`Null ~some:(fun v -> `String v) portrait_opt);
            ( "background",
              Option.fold ~none:`Null ~some:(fun v -> `String v) background_opt );
            ("stats", Option.value ~default:`Null stats_opt);
            ("hp", `Int hp);
            ("max_hp", `Int max_hp);
            ("alive", `Bool alive);
            ("traits", json_of_strings traits);
            ("skills", json_of_strings skills);
            ("inventory", json_of_strings inventory);
          ]
      in
      Ok actor_json

let actor_patch_from_update_args args =
  let ( let* ) = Result.bind in
  let* role_opt = get_optional_string args "role" in
  let* () =
    match role_opt with
    | Some role -> validate_actor_role role
    | None -> Ok ()
  in
  let* name_opt = get_optional_string args "name" in
  let* archetype_opt = get_optional_string args "archetype" in
  let* persona_opt = get_optional_string args "persona" in
  let* portrait_opt = get_optional_string args "portrait" in
  let* background_opt = get_optional_string args "background" in
  let* stats_opt = get_optional_object args "stats" in
  let* hp_opt = get_optional_int args "hp" in
  let* max_hp_opt = get_optional_int args "max_hp" in
  let* traits_opt = get_optional_string_list_option args "traits" in
  let* skills_opt = get_optional_string_list_option args "skills" in
  let* inventory_opt = get_optional_string_list_option args "inventory" in
  let alive_opt =
    match args |> member "alive" with
    | `Bool b -> Ok (Some b)
    | `Null -> Ok None
    | _ -> Error "alive must be boolean"
  in
  let* alive_opt = alive_opt in
  let alive_opt =
    match alive_opt, hp_opt with
    | Some v, _ -> Some v
    | None, Some hp -> Some (hp > 0)
    | None, None -> None
  in
  let* () =
    match max_hp_opt with
    | Some v when v <= 0 -> Error "max_hp must be > 0"
    | _ -> Ok ()
  in
  let* () =
    match hp_opt with
    | Some v when v < 0 -> Error "hp must be >= 0"
    | _ -> Ok ()
  in
  let fields = ref [] in
  let add_opt_string key = function
    | Some value -> fields := (key, `String value) :: !fields
    | None -> ()
  in
  let add_opt_int key = function
    | Some value -> fields := (key, `Int value) :: !fields
    | None -> ()
  in
  let add_opt_bool key = function
    | Some value -> fields := (key, `Bool value) :: !fields
    | None -> ()
  in
  let add_opt_strings key = function
    | Some values -> fields := (key, json_of_strings values) :: !fields
    | None -> ()
  in
  let add_opt_json key = function
    | Some value -> fields := (key, value) :: !fields
    | None -> ()
  in
  add_opt_string "role" role_opt;
  add_opt_string "name" name_opt;
  add_opt_string "archetype" archetype_opt;
  add_opt_string "persona" persona_opt;
  add_opt_string "portrait" portrait_opt;
  add_opt_string "background" background_opt;
  add_opt_json "stats" stats_opt;
  add_opt_int "hp" hp_opt;
  add_opt_int "max_hp" max_hp_opt;
  add_opt_bool "alive" alive_opt;
  add_opt_strings "traits" traits_opt;
  add_opt_strings "skills" skills_opt;
  add_opt_strings "inventory" inventory_opt;
  if !fields = [] then
    Error
      "at least one update field is required: role,name,archetype,persona,portrait,background,stats,hp,max_hp,alive,traits,skills,inventory"
  else Ok (`Assoc (List.rev !fields))

let handle_actor_spawn ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id_opt = get_optional_string args "actor_id" in
    let* name_opt = get_optional_string args "name" in
    let* role_opt = get_optional_string args "role" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let actor_id =
      match actor_id_opt with
      | Some explicit -> explicit
      | None ->
          let seed =
            match name_opt with
            | Some name -> name
            | None ->
                role_opt |> Option.value ~default:"player"
                |> String.lowercase_ascii
          in
          let base_actor_id = sanitize_actor_id_seed seed in
          next_available_actor_id state base_actor_id
    in
    if actor_exists_in_state state actor_id then
      Error (Printf.sprintf "actor already exists: %s" actor_id)
    else
      let* actor_json = actor_payload_from_spawn_args args ~actor_id in
      let payload =
        `Assoc
          [
            ("actor_id", `String actor_id);
            ("actor", actor_json);
            ("spawned_by", `String ctx.agent_name);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Actor_spawned
          ~actor_id ~payload ()
      in
      let* next_derived = derive_state ~store ~room_id ~rule_module in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("event", Trpg_engine_event.to_yojson event);
            ("state", state_of_derived next_derived);
          ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_actor_update ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    if not (actor_exists_in_state state actor_id) then
      Error (Printf.sprintf "unknown actor_id: %s" actor_id)
    else
      let* actor_patch = actor_patch_from_update_args args in
      let payload =
        `Assoc
          [
            ("actor_id", `String actor_id);
            ("actor_patch", actor_patch);
            ("updated_by", `String ctx.agent_name);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Actor_updated
          ~actor_id ~payload ()
      in
      let* next_derived = derive_state ~store ~room_id ~rule_module in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("event", Trpg_engine_event.to_yojson event);
            ("state", state_of_derived next_derived);
          ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_actor_delete ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* reason_opt = get_optional_string args "reason" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    if not (actor_exists_in_state state actor_id) then
      Error (Printf.sprintf "unknown actor_id: %s" actor_id)
    else
      let payload =
        `Assoc
          [
            ("actor_id", `String actor_id);
            ("reason", Option.fold ~none:`Null ~some:(fun v -> `String v) reason_opt);
            ("deleted_by", `String ctx.agent_name);
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Actor_deleted
          ~actor_id ~payload ()
      in
      let* next_derived = derive_state ~store ~room_id ~rule_module in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("status", `String "deleted");
            ("event", Trpg_engine_event.to_yojson event);
            ("state", state_of_derived next_derived);
          ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

(* ---------- Actor Match (advisory keeper-actor ranking) ---------- *)

let parse_keeper_entry (j : Yojson.Safe.t) :
    (string * string * string, string) Stdlib.result =
  let ( let* ) = Result.bind in
  match j with
  | `Assoc _ ->
      let* name =
        match j |> member "name" with
        | `String s when String.trim s <> "" -> Ok (String.trim s)
        | _ -> Error "keeper entry missing 'name'"
      in
      let style =
        match j |> member "style" with
        | `String s -> String.trim s
        | _ -> ""
      in
      let description =
        match j |> member "description" with
        | `String s -> String.trim s
        | _ -> ""
      in
      Ok (name, style, description)
  | _ -> Error "keeper entry must be an object"

let parse_keeper_list (j : Yojson.Safe.t) :
    ((string * string * string) list, string) Stdlib.result =
  match j with
  | `List xs ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | x :: rest -> (
            match parse_keeper_entry x with
            | Ok entry -> go (entry :: acc) rest
            | Error e -> Error e)
      in
      go [] xs
  | _ -> Error "keepers must be a JSON array"

let handle_actor_match ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* keepers_json =
      match args |> member "keepers" with
      | `Null -> Error "missing required field: keepers"
      | j -> Ok j
    in
    let* keepers = parse_keeper_list keepers_json in
    if keepers = [] then
      Error "keepers array must not be empty"
    else
      let* actor_id_opt = get_optional_string args "actor_id" in
      let* rule_opt = get_optional_string args "rule_module" in
      let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
      let* () = validate_rule_module rule_module in
      let* derived = derive_state ~store ~room_id ~rule_module in
      let state = state_of_derived derived in
      let party = state_party_fields state in
      let target_actors =
        match actor_id_opt with
        | Some id -> (
            match List.assoc_opt id party with
            | Some aj -> [ (id, aj) ]
            | None -> [])
        | None ->
            (* Only include alive actors with player role *)
            party
            |> List.filter (fun (_id, aj) ->
                   let alive =
                     aj |> member "alive" |> to_bool_option
                     |> Option.value ~default:true
                   in
                   alive)
      in
      if target_actors = [] then
        Error
          (match actor_id_opt with
          | Some id -> Printf.sprintf "actor not found: %s" id
          | None -> "no alive actors in room")
      else
        let rankings =
          target_actors
          |> List.map (fun (actor_id, actor_json) ->
                 let archetype = get_string_field actor_json "archetype" in
                 let traits = get_string_list_field actor_json "traits" in
                 let persona = get_string_field actor_json "persona" in
                 let scores =
                   Trpg_actor_match.rank ~keepers ~actor_id
                     ~actor_archetype:archetype ~actor_traits:traits
                     ~actor_persona:persona
                 in
                 ( actor_id,
                   `Assoc
                     [
                       ("actor_id", `String actor_id);
                       ("archetype", `String archetype);
                       ( "rankings",
                         Trpg_actor_match.ranking_to_yojson scores );
                       ( "best_keeper",
                         match scores with
                         | best :: _ -> `String best.keeper_name
                         | [] -> `Null );
                     ] ))
        in
        Ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ( "actor_rankings",
                `List (List.map (fun (_id, j) -> j) rankings) );
              ("keeper_count", `Int (List.length keepers));
              ("actor_count", `Int (List.length target_actors));
            ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_actor_claim ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name = get_required_string args "keeper_name" in
    let* keeper_style_opt = get_optional_string args "keeper_style" in
    let* keeper_desc_opt = get_optional_string args "keeper_description" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let* events = store.read_events ~room_id in
    if not (actor_exists_in_state state actor_id) then
      Error (Printf.sprintf "unknown actor_id: %s" actor_id)
    else if not (actor_alive_in_state state actor_id) then
      Error (Printf.sprintf "actor is not alive: %s" actor_id)
    else
      let actor_role = actor_role_in_state state actor_id in
      let phase_name =
        match state |> member "phase" with
        | `String phase -> String.lowercase_ascii (String.trim phase)
        | _ -> "round"
      in
      let* () =
        if actor_role <> "player" then Ok ()
        else if phase_name <> "round" then
          (* Initial party assignment (briefing/setup) should not be blocked by
             mid-join contribution gate. *)
          Ok ()
        else
          let gate = join_gate_of_state state in
          let score, _reasons = contribution_for_actor_from_events events actor_id in
          if not gate.phase_open then
            Error
              (Printf.sprintf
                 "join gate failed: code=join_window_closed actor_id=%s window=%s"
                 actor_id gate.window)
          else if score < gate.min_points then
            Error
              (Printf.sprintf
                 "join gate failed: code=insufficient_contribution actor_id=%s score=%d required=%d"
                 actor_id score gate.min_points)
          else Ok ()
      in
      let normalized_keeper = normalize_keeper_name keeper_name in
      match owner_for_actor state actor_id with
      | Some owner when normalize_keeper_name owner = normalized_keeper ->
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("room_id", `String room_id);
                ("actor_id", `String actor_id);
                ("keeper_name", `String owner);
                ("status", `String "already_claimed");
                ("state", state);
              ])
      | Some owner ->
          Error
            (Printf.sprintf
               "actor already claimed: actor_id=%s owner=%s"
               actor_id owner)
      | None -> (
          match actor_for_keeper state keeper_name with
          | Some current_actor ->
              Error
                (Printf.sprintf
                   "keeper already controls actor: keeper=%s actor_id=%s"
                   keeper_name current_actor)
          | None ->
              let payload =
                `Assoc
                  [
                    ("actor_id", `String actor_id);
                    ("keeper_name", `String keeper_name);
                    ("claimed_by", `String ctx.agent_name);
                  ]
              in
              let* event =
                append_event ~store ~room_id
                  ~event_type:Trpg_engine_event.Actor_claimed
                  ~actor_id ~payload ()
              in
              let* next_derived = derive_state ~store ~room_id ~rule_module in
              (* Compute optional match_score when keeper metadata is provided *)
              let match_score_field =
                match (keeper_style_opt, keeper_desc_opt) with
                | (Some style, Some description) ->
                    let actor_json =
                      match List.assoc_opt actor_id (state_party_fields state) with
                      | Some aj -> aj
                      | None -> `Assoc []
                    in
                    let archetype = get_string_field actor_json "archetype" in
                    let traits = get_string_list_field actor_json "traits" in
                    let persona = get_string_field actor_json "persona" in
                    let ms =
                      Trpg_actor_match.score
                        ~keeper_name ~keeper_style:style
                        ~keeper_description:description
                        ~actor_id ~actor_archetype:archetype
                        ~actor_traits:traits ~actor_persona:persona
                    in
                    [ ("match_score", Trpg_actor_match.to_yojson ms) ]
                | _ -> []
              in
              Ok
                (`Assoc
                  ([
                    ("ok", `Bool true);
                    ("room_id", `String room_id);
                    ("actor_id", `String actor_id);
                    ("keeper_name", `String keeper_name);
                    ("status", `String "claimed");
                    ("event", Trpg_engine_event.to_yojson event);
                    ("state", state_of_derived next_derived);
                  ] @ match_score_field)) )
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_actor_release ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name = get_required_string args "keeper_name" in
    let* reason_opt = get_optional_string args "reason" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let normalized_keeper = normalize_keeper_name keeper_name in
    match owner_for_actor state actor_id with
    | None ->
        Error (Printf.sprintf "actor is not claimed: %s" actor_id)
    | Some owner when normalize_keeper_name owner <> normalized_keeper ->
        Error
          (Printf.sprintf
             "actor is claimed by another keeper: actor_id=%s owner=%s"
             actor_id owner)
    | Some owner ->
        let payload =
          `Assoc
            [
              ("actor_id", `String actor_id);
              ("keeper_name", `String owner);
              ("reason", Option.fold ~none:`Null ~some:(fun v -> `String v) reason_opt);
              ("released_by", `String ctx.agent_name);
            ]
        in
        let* event =
          append_event ~store ~room_id
            ~event_type:Trpg_engine_event.Actor_released
            ~actor_id ~payload ()
        in
        let* next_derived = derive_state ~store ~room_id ~rule_module in
        Ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ("actor_id", `String actor_id);
              ("keeper_name", `String owner);
              ("status", `String "released");
              ("event", Trpg_engine_event.to_yojson event);
              ("state", state_of_derived next_derived);
            ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

