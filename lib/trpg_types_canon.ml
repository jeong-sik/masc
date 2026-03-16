(** Trpg_types_canon — canon checks, stagnation detection, combat semantics,
    and structured action types. *)

open Yojson.Safe.Util

include Trpg_types_world

let dedupe_keep_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: tl ->
        if List.mem x seen then loop seen acc tl
        else loop (x :: seen) (x :: acc) tl
  in
  loop [] [] xs

type canon_check = {
  enabled : bool;
  contract_id : string option;
  strict : bool;
  status : string;
  violations : string list;
  warnings : string list;
  required_flags_missing : string list;
  forbidden_flags_hit : string list;
  required_event_types_missing : string list;
  required_event_types_any_of_missing : string list;
  banned_terms_hit : string list;
}

let canon_check_to_yojson (check : canon_check) : Yojson.Safe.t =
  let strings_json xs = `List (List.map (fun value -> `String value) xs) in
  `Assoc
    [
      ("enabled", `Bool check.enabled);
      ( "contract_id",
        match check.contract_id with
        | Some id -> `String id
        | None -> `Null );
      ("strict", `Bool check.strict);
      ("status", `String check.status);
      ("violations", strings_json check.violations);
      ("warnings", strings_json check.warnings);
      ("required_flags_missing", strings_json check.required_flags_missing);
      ("forbidden_flags_hit", strings_json check.forbidden_flags_hit);
      ( "required_event_types_missing",
        strings_json check.required_event_types_missing );
      ( "required_event_types_any_of_missing",
        strings_json check.required_event_types_any_of_missing );
      ("banned_terms_hit", strings_json check.banned_terms_hit);
    ]

let canon_check_disabled : canon_check =
  {
    enabled = false;
    contract_id = None;
    strict = false;
    status = "disabled";
    violations = [];
    warnings = [];
    required_flags_missing = [];
    forbidden_flags_hit = [];
    required_event_types_missing = [];
    required_event_types_any_of_missing = [];
    banned_terms_hit = [];
  }

let canon_contract_ref_from_state (state : Yojson.Safe.t) :
    (string * bool) option =
  match state |> member "world" with
  | `Assoc world_fields -> (
      match List.assoc_opt "canon_contract" world_fields with
      | Some (`Assoc canon_fields) ->
          let canon_json = `Assoc canon_fields in
          let id_opt =
            match List.assoc_opt "id" canon_fields with
            | Some (`String raw) ->
                let id = String.trim raw in
                if id = "" then None else Some id
            | _ -> None
          in
          (match id_opt with
          | None -> None
          | Some id ->
              let strict =
                canon_json |> member "strict" |> to_bool_option
                |> Option.value ~default:false
              in
              Some (id, strict))
      | _ -> None)
  | _ -> None

let evaluate_canon_check ~store ~state ~events ~dm_reply : canon_check =
  match canon_contract_ref_from_state state with
  | None -> canon_check_disabled
  | Some (contract_id, strict) -> (
      let catalog = load_world_contract_catalog ~store in
      match find_world_contract catalog ~id:contract_id with
      | None ->
          {
            enabled = true;
            contract_id = Some contract_id;
            strict;
            status = "warn";
            violations = [];
            warnings =
              [ Printf.sprintf "contract_not_found:%s" contract_id ];
            required_flags_missing = [];
            forbidden_flags_hit = [];
            required_event_types_missing = [];
            required_event_types_any_of_missing = [];
            banned_terms_hit = [];
          }
      | Some contract ->
          let story_flags = story_flags_from_state state in
          let has_story_flag candidate =
            story_flags
            |> List.exists (fun flag ->
                   String.equal
                     (String.lowercase_ascii (String.trim flag))
                     (String.lowercase_ascii (String.trim candidate)))
          in
          let required_flags_missing =
            contract.required_flags
            |> List.filter (fun flag -> not (has_story_flag flag))
          in
          let forbidden_flags_hit =
            contract.forbidden_flags
            |> List.filter has_story_flag
          in
          let event_types_seen =
            events
            |> List.map (fun (event : Trpg_engine_event.t) ->
                   Trpg_engine_event.string_of_event_type event.event_type)
            |> dedupe_keep_order
          in
          let required_event_types_missing =
            contract.required_event_types
            |> List.filter (fun required ->
                   not (List.mem required event_types_seen))
          in
          let required_event_types_any_of_missing =
            contract.required_event_types_any_of
            |> List.filter_map (fun choices ->
                   let satisfied =
                     choices
                     |> List.exists (fun event_type ->
                            List.mem event_type event_types_seen)
                   in
                   if satisfied then None
                   else Some (String.concat "|" choices))
          in
          let dm_reply_lower =
            dm_reply
            |> Option.value ~default:""
            |> String.lowercase_ascii
          in
          let banned_terms_hit =
            contract.banned_terms
            |> List.filter (fun term ->
                   let token =
                     term |> String.trim |> String.lowercase_ascii
                   in
                   token <> "" && contains_substring dm_reply_lower token)
          in
          let violations =
            []
            |> (fun acc ->
                 acc
                 @ List.map
                     (fun flag ->
                       Printf.sprintf "required_flag_missing:%s" flag)
                     required_flags_missing)
            |> (fun acc ->
                 acc
                 @ List.map
                     (fun flag ->
                       Printf.sprintf "forbidden_flag_present:%s" flag)
                     forbidden_flags_hit)
            |> (fun acc ->
                 acc
                 @ List.map
                     (fun term ->
                       Printf.sprintf "banned_term_detected:%s" term)
                     banned_terms_hit)
          in
          let warnings =
            (List.map
               (fun ev ->
                 Printf.sprintf "required_event_type_missing:%s" ev)
               required_event_types_missing)
            @
            (List.map
               (fun choices ->
                 Printf.sprintf "required_event_type_any_of_missing:%s"
                   choices)
               required_event_types_any_of_missing)
          in
          let status =
            if violations <> [] then if strict then "fail" else "warn"
            else if warnings <> [] then "warn"
            else "pass"
          in
          {
            enabled = true;
            contract_id = Some contract.id;
            strict;
            status;
            violations;
            warnings;
            required_flags_missing;
            forbidden_flags_hit;
            required_event_types_missing;
            required_event_types_any_of_missing;
            banned_terms_hit;
          })

let is_meaningful_event_type = function
  | Trpg_engine_event.Flag_set
  | Trpg_engine_event.Combat_attack
  | Trpg_engine_event.Combat_defense
  | Trpg_engine_event.Scene_transition
  | Trpg_engine_event.Quest_update
  | Trpg_engine_event.Hp_changed
  | Trpg_engine_event.Inventory_changed ->
      true
  | _ -> false

let detect_stagnation ~(events : Trpg_engine_event.t list) ~threshold =
  let turn_events =
    events
    |> List.filter (fun (ev : Trpg_engine_event.t) ->
           ev.event_type = Trpg_engine_event.Turn_started)
    |> List.length
  in
  if turn_events < threshold then false
  else
    let recent_events =
      let rev = List.rev events in
      let rec take_until_n_turns n acc = function
        | [] -> acc
        | (ev : Trpg_engine_event.t) :: rest ->
            if n <= 0 then acc
            else
              let n' =
                if ev.event_type = Trpg_engine_event.Turn_started then n - 1
                else n
              in
              take_until_n_turns n' (ev :: acc) rest
      in
      take_until_n_turns threshold [] rev
    in
    not (List.exists (fun (ev : Trpg_engine_event.t) ->
             is_meaningful_event_type ev.event_type) recent_events)

let stagnation_detection_turn_threshold = 5
let stagnation_escalation_threshold = 3

let latest_stagnation_pressure_level ~(events : Trpg_engine_event.t list) : int =
  let latest_meaningful_seq =
    events
    |> List.fold_left
         (fun acc (ev : Trpg_engine_event.t) ->
           if is_meaningful_event_type ev.event_type then max acc ev.seq else acc)
         0
  in
  let latest_pressure_seq, latest_pressure_level =
    events
    |> List.fold_left
         (fun (best_seq, best_level) (ev : Trpg_engine_event.t) ->
           if ev.event_type <> Trpg_engine_event.World_event then
             (best_seq, best_level)
           else
             let event_type =
               match ev.payload |> member "event_type" with
               | `String raw -> String.lowercase_ascii (String.trim raw)
               | _ -> ""
             in
             if event_type <> "stagnation_pressure" then
               (best_seq, best_level)
             else
               let level =
                 match ev.payload |> member "stagnation_level" with
                 | `Int n when n > 0 -> n
                 | _ -> 1
               in
               if ev.seq >= best_seq then (ev.seq, level)
               else (best_seq, best_level))
         (0, 0)
  in
  if latest_pressure_seq = 0 || latest_meaningful_seq > latest_pressure_seq then 0
  else latest_pressure_level

let has_event_type (events : Trpg_engine_event.t list) event_type =
  List.exists
    (fun (ev : Trpg_engine_event.t) -> ev.event_type = event_type)
    events

let is_session_marker_event = function
  | Trpg_engine_event.Room_started
  | Trpg_engine_event.Session_started
  | Trpg_engine_event.Room_created ->
      true
  | _ -> false

let events_since_last_session_marker (events : Trpg_engine_event.t list) :
    Trpg_engine_event.t list =
  let rec collect acc = function
    | [] -> acc
    | (ev : Trpg_engine_event.t) :: tl ->
        let acc' = ev :: acc in
        if is_session_marker_event ev.event_type then acc' else collect acc' tl
  in
  collect [] (List.rev events)

let latest_session_outcome_payload (events : Trpg_engine_event.t list) :
    Yojson.Safe.t option =
  events
  |> List.fold_left
       (fun acc (ev : Trpg_engine_event.t) ->
         if ev.event_type = Trpg_engine_event.Session_outcome then
           Some (ensure_outcome_payload_source ev.payload)
         else acc)
       None

type combat_semantic =
  | Combat_attack_intent
  | Combat_defense_intent

type action_type =
  | Attack
  | Defend
  | Heal
  | Investigate
  | Social
  | Explore
  | Magic
  | UseItem
  | SetFlag
  | SceneTransition
  | QuestUpdate

type memory_tier =
  | Memory_short
  | Memory_mid
  | Memory_long

type structured_memory_hint = {
  requested_tier : memory_tier;
  importance_score : int option;
  reason : string option;
}

type structured_action = {
  sa_type : action_type;
  target_id : string option;
  description : string;
  flag_key : string option;
  scene : string option;
  quest_info : string option;
  memory_hint : structured_memory_hint option;
  raw_payload : Yojson.Safe.t;
}

let first_nonempty_string_field keys (json : Yojson.Safe.t) =
  keys
  |> List.find_map (fun key ->
         match json |> member key with
         | `String s when String.trim s <> "" -> Some (String.trim s)
         | _ -> None)

