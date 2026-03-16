(** Trpg_round — session setup, keeper integration, observability.
    Fallback replies in Trpg_round_fallback, parsing in Trpg_round_keeper_parse,
    prompt building in Trpg_round_prompt. *)

include Trpg_round_prompt
open Yojson.Safe.Util

let room_id_for_session session_id =
  sanitize_room_id (Printf.sprintf "session-%s" session_id)

let json_of_strings xs = `List (List.map (fun s -> `String s) xs)

let pool_member_of_json (json : Yojson.Safe.t) :
    (pool_member, string) Stdlib.result =
  let ( let* ) = Result.bind in
  let string_list_field json key =
    match json |> member key with
    | `List _ as value -> get_string_list_from_json value
    | `Null -> Ok []
    | _ -> Error (Printf.sprintf "pool item.%s must be string array" key)
  in
  let as_assoc =
    match json with
    | `Assoc _ -> Ok json
    | _ -> Error "pool item must be object"
  in
  let* json = as_assoc in
  let* actor_id =
    match json |> member "actor_id" with
    | `String s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error "pool item.actor_id is required"
  in
  let* name =
    match json |> member "name" with
    | `String s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error (Printf.sprintf "pool item.name is required for actor_id=%s" actor_id)
  in
  let archetype =
    match json |> member "archetype" with
    | `String s when String.trim s <> "" -> String.trim s
    | _ -> "unknown"
  in
  let persona =
    match json |> member "persona" with
    | `String s -> s
    | _ -> ""
  in
  let* traits = string_list_field json "traits" in
  let* skill_ids = string_list_field json "skill_ids" in
  let keeper_name = json |> member "keeper_name" |> to_string_option in
  let source_preset_id =
    match json |> member "source_preset_id" with
    | `String s when String.trim s <> "" -> String.trim s
    | _ -> actor_id
  in
  Ok
    {
      actor_id;
      name;
      archetype;
      persona;
      traits;
      skill_ids;
      keeper_name;
      source_preset_id;
    }

let pool_members_of_json_list xs =
  let ( let* ) = Result.bind in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | x :: tl ->
        let* m = pool_member_of_json x in
        loop (m :: acc) tl
  in
  let* members = loop [] xs in
  Ok
    (members
    |> List.sort (fun a b -> String.compare a.actor_id b.actor_id))

let party_member_config (m : pool_member) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String m.name);
      ("archetype", `String m.archetype);
      ("persona", `String m.persona);
      ("traits", json_of_strings m.traits);
      ("skills", json_of_strings m.skill_ids);
      ("hp", `Int 10);
      ("max_hp", `Int 10);
      ("alive", `Bool true);
      ("inventory", `List []);
    ]

let party_config (members : pool_member list) : Yojson.Safe.t =
  `Assoc
    (List.map
       (fun (m : pool_member) -> (m.actor_id, party_member_config m))
       members)

let world_config ~(preset : Trpg_preset_store.world_preset) : Yojson.Safe.t =
  `Assoc
    [
      ("preset_id", `String preset.id);
      ("title", `String preset.title);
      ("description", `String preset.description);
      ("intro", `String preset.intro);
      ("story_flags", json_of_strings preset.initial_flags);
      ("end_rules", Trpg_preset_store.end_rules_to_yojson preset.end_rules);
    ]

let dm_config ~(preset : Trpg_preset_store.dm_preset) ~dm_keeper : Yojson.Safe.t =
  `Assoc
    [
      ("preset_id", `String preset.id);
      ("title", `String preset.title);
      ("style", `String preset.style);
      ("opening_prompt", `String preset.opening_prompt);
      ("tags", json_of_strings preset.tags);
      ("keeper_name", `String dm_keeper);
    ]

let derive_pending_interventions (events : Trpg_engine_event.t list) :
    (int * string * Yojson.Safe.t) list =
  let submitted = ref [] in
  let applied = Hashtbl.create 16 in
  List.iter
    (fun (ev : Trpg_engine_event.t) ->
      match ev.event_type with
      | Trpg_engine_event.Intervention_submitted -> (
          match ev.payload |> member "intervention_id" with
          | `String intervention_id when String.trim intervention_id <> "" ->
              submitted := (ev.seq, intervention_id, ev.payload) :: !submitted
          | _ -> ())
      | Trpg_engine_event.Intervention_applied -> (
          match ev.payload |> member "intervention_id" with
          | `String intervention_id when String.trim intervention_id <> "" ->
              Hashtbl.replace applied intervention_id true
          | _ -> ())
      | _ -> ())
    events;
  !submitted
  |> List.filter (fun (_, intervention_id, _) ->
         not (Hashtbl.mem applied intervention_id))
  |> List.sort (fun (a, _, _) (b, _, _) -> Int.compare a b)

let inject_interventions_into_state state interventions =
  match state with
  | `Assoc fields ->
      `Assoc
        (("interventions", `List interventions)
        :: List.filter (fun (k, _) -> k <> "interventions") fields)
  | _ -> state

let call_keeper ctx ~name ~message ~timeout_sec =
  match ctx.keeper_call with
  | None -> `Error "keeper_call is not available in this runtime"
  | Some f -> f ~name ~message ~timeout_sec

let keeper_unavailable_max_per_turn_default = 8

let keeper_unavailable_max_per_turn_env =
  "MASC_TRPG_KEEPER_UNAVAILABLE_MAX_PER_TURN"

let keeper_unavailable_max_per_turn () =
  match Sys.getenv_opt keeper_unavailable_max_per_turn_env with
  | None -> keeper_unavailable_max_per_turn_default
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value when value >= 0 -> value
      | _ -> keeper_unavailable_max_per_turn_default)

type unavailable_sampling_state = {
  max_per_turn : int;
  mutable count_in_turn : int;
  seen_keys : (string, unit) Hashtbl.t;
}

type unavailable_append_result =
  [ `Appended of Trpg_engine_event.t | `Sampled of string ]

let unavailable_sampling_key ~turn ~actor_id ~keeper_name ~stage ~reason =
  Printf.sprintf "%d|%s|%s|%s|%s" turn actor_id
    (normalize_keeper_name keeper_name)
    (String.lowercase_ascii (String.trim stage))
    (String.lowercase_ascii (String.trim reason))

let make_unavailable_sampling_state ~(events : Trpg_engine_event.t list) ~turn :
    unavailable_sampling_state =
  let seen_keys = Hashtbl.create 64 in
  let count_in_turn = ref 0 in
  List.iter
    (fun (event : Trpg_engine_event.t) ->
      if event.event_type = Trpg_engine_event.Keeper_unavailable then
        let payload_turn =
          match event.payload |> member "turn" with
          | `Int i -> Some i
          | _ -> None
        in
        match payload_turn with
        | Some payload_turn when payload_turn = turn ->
            count_in_turn := !count_in_turn + 1;
            let actor_id =
              match event.payload |> member "actor_id" with
              | `String v -> v
              | _ ->
                  Option.value ~default:"" event.actor_id |> String.trim
            in
            let keeper_name =
              match event.payload |> member "keeper" with
              | `String v -> v
              | _ -> ""
            in
            let stage =
              match event.payload |> member "stage" with
              | `String v -> v
              | _ -> ""
            in
            let reason =
              match event.payload |> member "reason" with
              | `String v -> v
              | _ -> ""
            in
            if actor_id <> "" && keeper_name <> "" && stage <> "" then
              let key =
                unavailable_sampling_key ~turn ~actor_id ~keeper_name ~stage
                  ~reason
              in
              Hashtbl.replace seen_keys key ()
        | _ -> ())
    events;
  {
    max_per_turn = keeper_unavailable_max_per_turn ();
    count_in_turn = !count_in_turn;
    seen_keys;
  }

let decide_unavailable_append ~sampling_state ~turn ~actor_id ~keeper_name ~stage
    ~reason : [ `Append | `Sampled of string ] =
  let key = unavailable_sampling_key ~turn ~actor_id ~keeper_name ~stage ~reason in
  if Hashtbl.mem sampling_state.seen_keys key then `Sampled "duplicate"
  else if sampling_state.count_in_turn >= sampling_state.max_per_turn then
    `Sampled
      (Printf.sprintf "cap:%d" (max 0 sampling_state.max_per_turn))
  else (
    Hashtbl.replace sampling_state.seen_keys key ();
    sampling_state.count_in_turn <- sampling_state.count_in_turn + 1;
    `Append)

let rec append_timeout_and_unavailable_events
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~timeout_sec
    ~sampling_state
    =
  let ( let* ) = Result.bind in
  let timeout_reason = "timeout" in
  let timeout_stage = "masc_keeper_msg" in
  let timeout_payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("reason", `String timeout_reason);
        ("timeout_sec", `Float timeout_sec);
        ("stage", `String timeout_stage);
      ]
  in
  let* timeout_event =
    append_event
      ~store
      ~room_id
      ~event_type:Trpg_engine_event.Turn_timeout
      ~actor_id
      ~payload:timeout_payload
      ()
  in
  let* unavailable_result =
    append_unavailable_event
      ~store
      ~room_id
      ~phase
      ~turn
      ~role
      ~actor_id
      ~keeper_name
      ~reason:timeout_reason
      ~stage:timeout_stage
      ~sampling_state
      ~extra_payload_fields:[ ("timeout_sec", `Float timeout_sec) ]
      ()
  in
  Ok (timeout_event, unavailable_result)

and append_unavailable_event
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~reason
    ~stage
    ~sampling_state
    ?(extra_payload_fields = [])
    ()
    =
  match
    decide_unavailable_append ~sampling_state ~turn ~actor_id ~keeper_name
      ~stage ~reason
  with
  | `Sampled sampled_reason -> Ok (`Sampled sampled_reason)
  | `Append ->
      let payload =
        `Assoc
          ([
             ("phase", `String phase);
             ("turn", `Int turn);
             ("role", `String (role_to_string role));
             ("actor_id", `String actor_id);
             ("keeper", `String keeper_name);
             ("reason", `String reason);
             ("stage", `String stage);
           ]
          @ extra_payload_fields)
      in
      append_event
        ~store
        ~room_id
        ~event_type:Trpg_engine_event.Keeper_unavailable
        ~actor_id
        ~payload
        ()
      |> Result.map (fun event -> `Appended event)

let append_keeper_reply_event
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~reply
    =
  let (event_type, payload) =
    match role with
    | `Dm ->
        ( Trpg_engine_event.Narration_posted,
          `Assoc
            [
              ("phase", `String phase);
              ("turn", `Int turn);
              ("role", `String "dm");
              ("actor_id", `String actor_id);
              ("keeper", `String keeper_name);
              ("reply", `String reply);
            ] )
    | `Player ->
        ( Trpg_engine_event.Turn_action_proposed,
          `Assoc
            [
              ("phase", `String phase);
              ("turn", `Int turn);
              ("role", `String "player");
              ("actor_id", `String actor_id);
              ("keeper", `String keeper_name);
              ("proposed_action", `String reply);
            ] )
  in
  append_event
    ~store
    ~room_id
    ~event_type
    ~actor_id
    ~payload
    ()

let deterministic_raw_d20 ~turn ~actor_id ~salt =
  let hash = Hashtbl.hash (actor_id ^ ":" ^ string_of_int turn ^ ":" ^ salt) in
  1 + ((if hash < 0 then -hash else hash) mod 20)

let action_type_requires_round_dice = function
  | Attack | Defend -> true
  | Heal | Investigate | Social | Explore | Magic | UseItem | SetFlag
  | SceneTransition | QuestUpdate ->
      false

let resolved_effects_of_events (events : Trpg_engine_event.t list) : Yojson.Safe.t list =
  let rec collect seen acc = function
    | [] -> List.rev acc
    | (event : Trpg_engine_event.t) :: tl ->
        let event_name = Trpg_engine_event.string_of_event_type event.event_type in
        if List.mem event_name seen then collect seen acc tl
        else collect (event_name :: seen) (`String ("event:" ^ event_name) :: acc) tl
  in
  collect [] [] events

let append_round_observability_events
    ~store
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~reply
    ~(sa : structured_action)
    ~action_events
    ~resolution_source
    ~fallback
    =
  let ( let* ) = Result.bind in
  let* dice_event_opt =
    if
      role = `Player
      && action_type_requires_round_dice sa.sa_type
      && not
           (List.exists
              (fun (event : Trpg_engine_event.t) ->
                event.event_type = Trpg_engine_event.Dice_rolled)
              action_events)
    then
      let raw_d20 =
        deterministic_raw_d20 ~turn ~actor_id
          ~salt:(string_of_action_type sa.sa_type)
      in
      let stat_value = 12 in
      let dc = 10 in
      let bonus = Trpg_rule_dnd5e_lite.stat_bonus stat_value in
      let total = raw_d20 + bonus in
      let c = Trpg_rule_dnd5e_lite.classify_roll ~raw_d20 ~total in
      let payload =
        `Assoc
          [
            ("phase", `String phase);
            ("turn", `Int turn);
            ("actor_id", `String actor_id);
            ("keeper", `String keeper_name);
            ("action", `String sa.description);
            ("action_type", `String (string_of_action_type sa.sa_type));
            ("stat_value", `Int stat_value);
            ("dc", `Int dc);
            ("raw_d20", `Int raw_d20);
            ("bonus", `Int bonus);
            ("total", `Int total);
            ("tier", `String (Trpg_rule_dnd5e_lite.roll_tier_to_string c.tier));
            ("label", `String c.label);
            ("passed", `Bool c.passed);
            ("resolved_by", `String "deterministic_round_run");
            ("source", `String "round_run");
          ]
      in
      let* event =
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Dice_rolled ~actor_id ~payload ()
      in
      Ok (Some event)
    else Ok None
  in
  let observed_events =
    match dice_event_opt with
    | Some dice_event -> action_events @ [ dice_event ]
    | None -> action_events
  in
  let resolved_effects =
    let effects = resolved_effects_of_events observed_events in
    if effects = [] then
      [ `String ("action.applied:" ^ string_of_action_type sa.sa_type) ]
    else effects
  in
  let payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("reply", `String reply);
        ("action_type", `String (string_of_action_type sa.sa_type));
        ("next_scene_or_state", `String "turn.continue");
        ("resolved_effects", `List resolved_effects);
        ("resolution_source", `String resolution_source);
        ("fallback", `Bool fallback);
      ]
  in
  let* resolved_event =
    append_event ~store ~room_id
      ~event_type:Trpg_engine_event.Turn_action_resolved ~actor_id ~payload ()
  in
  Ok
    (match dice_event_opt with
    | Some dice_event -> [ dice_event; resolved_event ]
    | None -> [ resolved_event ])

