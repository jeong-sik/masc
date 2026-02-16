(** Tool_trpg - Strict TRPG action tools for AI agents.

    Exposes:
    - masc_trpg_dice_roll
    - masc_trpg_turn_advance
    - masc_trpg_stream
    - masc_trpg_round_run
    - masc_trpg_preset_list
    - masc_trpg_pool_generate
    - masc_trpg_party_select
    - masc_trpg_session_start
    - masc_trpg_actor_spawn
    - masc_trpg_actor_claim
    - masc_trpg_actor_release
    - masc_trpg_intervention_submit
*)

open Yojson.Safe.Util

type result = bool * string

type keeper_call_result = [ `Ok of Yojson.Safe.t | `Timeout | `Error of string ]

type context = {
  config : Room.config;
  agent_name : string;
  keeper_call :
    (name:string -> message:string -> timeout_sec:float -> keeper_call_result)
    option;
}

type trpg_role = [ `Dm | `Player ]

let role_to_string = function `Dm -> "dm" | `Player -> "player"

let normalize_keeper_name (s : string) : string =
  s |> String.trim |> String.lowercase_ascii

let validate_unique_keeper_assignments ~dm_keeper
    ~(player_keepers : (string * string) list) : (unit, string) Stdlib.result =
  let dm_keeper = String.trim dm_keeper in
  if dm_keeper = "" then Error "dm_keeper cannot be empty"
  else
    let seen : (string, string) Hashtbl.t = Hashtbl.create 16 in
    Hashtbl.replace seen (normalize_keeper_name dm_keeper) "dm";
    let rec loop = function
      | [] -> Ok ()
      | (actor_id, keeper_name) :: tl ->
          let actor_id = String.trim actor_id in
          let keeper_name = String.trim keeper_name in
          if actor_id = "" then Error "player actor_id cannot be empty"
          else if keeper_name = "" then
            Error (Printf.sprintf "keeper for actor %s cannot be empty" actor_id)
          else
            let key = normalize_keeper_name keeper_name in
            (match Hashtbl.find_opt seen key with
            | Some previous_owner ->
                Error
                  (Printf.sprintf
                     "keeper assignments must be unique: keeper '%s' is reused by %s and %s"
                     keeper_name previous_owner actor_id)
            | None ->
                Hashtbl.replace seen key actor_id;
                loop tl)
    in
    loop player_keepers

let keeper_busy_mutex = Mutex.create ()
let keeper_busy_counts : (string, int) Hashtbl.t = Hashtbl.create 128

let with_keeper_reservation ~(keepers : string list)
    (f : unit -> ('a, string) Stdlib.result) : ('a, string) Stdlib.result =
  let keeper_keys =
    keepers |> List.map normalize_keeper_name
    |> List.filter (fun k -> k <> "")
    |> List.sort_uniq String.compare
  in
  let reserve () =
    Mutex.lock keeper_busy_mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock keeper_busy_mutex)
      (fun () ->
        let busy =
          List.filter
            (fun key ->
              let cnt = Hashtbl.find_opt keeper_busy_counts key |> Option.value ~default:0 in
              cnt > 0)
            keeper_keys
        in
        if busy <> [] then
          Error
            (Printf.sprintf
               "keeper busy: %s (each spawned keeper can handle only one round at a time)"
               (String.concat ", " busy))
        else (
          List.iter
            (fun key ->
              let cnt = Hashtbl.find_opt keeper_busy_counts key |> Option.value ~default:0 in
              Hashtbl.replace keeper_busy_counts key (cnt + 1))
            keeper_keys;
          Ok ()))
  in
  let release () =
    Mutex.lock keeper_busy_mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock keeper_busy_mutex)
      (fun () ->
        List.iter
          (fun key ->
            let cnt = Hashtbl.find_opt keeper_busy_counts key |> Option.value ~default:0 in
            if cnt <= 1 then Hashtbl.remove keeper_busy_counts key
            else Hashtbl.replace keeper_busy_counts key (cnt - 1))
          keeper_keys)
  in
  match reserve () with
  | Error _ as e -> e
  | Ok () -> Fun.protect ~finally:release f

type pool_member = {
  actor_id : string;
  name : string;
  archetype : string;
  persona : string;
  traits : string list;
  skill_ids : string list;
  keeper_name : string option;
  source_preset_id : string;
}

let pool_member_to_yojson (m : pool_member) : Yojson.Safe.t =
  `Assoc
    [
      ("actor_id", `String m.actor_id);
      ("name", `String m.name);
      ("archetype", `String m.archetype);
      ("persona", `String m.persona);
      ("traits", `List (List.map (fun s -> `String s) m.traits));
      ("skill_ids", `List (List.map (fun s -> `String s) m.skill_ids));
      ( "keeper_name",
        Option.fold ~none:`Null ~some:(fun s -> `String s) m.keeper_name );
      ("source_preset_id", `String m.source_preset_id);
    ]

let schemas : Types.tool_schema list =
  [
    {
      name = "masc_trpg_dice_roll";
      description =
        "Roll D20 for an actor and append dice.rolled event. \
         Required: room_id, actor_id, action, stat_value, dc. \
         Optional: raw_d20 (1-20), rule_module (default: dnd5e-lite).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("action", `Assoc [ ("type", `String "string") ]);
                  ("stat_value", `Assoc [ ("type", `String "integer") ]);
                  ("dc", `Assoc [ ("type", `String "integer") ]);
                  ("raw_d20", `Assoc [ ("type", `String "integer") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List
                [
                  `String "room_id";
                  `String "actor_id";
                  `String "action";
                  `String "stat_value";
                  `String "dc";
                ] );
          ];
    };
    {
      name = "masc_trpg_turn_advance";
      description =
        "Advance turn by appending turn.started and optional phase.changed event. \
         Required: room_id. Optional: phase, rule_module.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
    {
      name = "masc_trpg_stream";
      description =
        "Read TRPG event stream window from storage. \
         Required: room_id. Optional: after_seq, event_type.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("after_seq", `Assoc [ ("type", `String "integer") ]);
                  ("event_type", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
    {
      name = "masc_trpg_round_run";
      description =
        "Run one TRPG round by messaging DM keeper then player keepers. \
         Records strict timeout/unavailable events. \
         Required: room_id, dm_keeper, player_keepers(object actor_id->keeper_name). \
         Optional: phase(default round), rule_module(default dnd5e-lite), timeout_sec(default 30), lang(ko|en), require_claim(boolean).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_keeper", `Assoc [ ("type", `String "string") ]);
                  ( "player_keepers",
                    `Assoc
                      [
                        ("type", `String "object");
                        ("additionalProperties", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                  ("timeout_sec", `Assoc [ ("type", `String "number") ]);
                  ("require_claim", `Assoc [ ("type", `String "boolean") ]);
                  ("lang", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List
                [ `String "room_id"; `String "dm_keeper"; `String "player_keepers" ] );
          ];
    };
    {
      name = "masc_trpg_scene_transition";
      description =
        "Record a scene transition event. Tracks quest progression and narrative flow. \
         Required: room_id, from_scene, to_scene. \
         Optional: trigger, narrative_hook.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("from_scene", `Assoc [ ("type", `String "string") ]);
                  ("to_scene", `Assoc [ ("type", `String "string") ]);
                  ("trigger", `Assoc [ ("type", `String "string") ]);
                  ("narrative_hook", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "from_scene"; `String "to_scene" ] );
          ];
    };
    {
      name = "masc_trpg_quest_update";
      description =
        "Record a quest state change. Tracks quest progression (active/completed/failed) \
         and objective completion. \
         Required: room_id, quest_id, title, status. \
         Optional: objectives (array of {desc, done}).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("quest_id", `Assoc [ ("type", `String "string") ]);
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "active"; `String "completed"; `String "failed";
                            ] );
                      ] );
                  ( "objectives",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ("type", `String "object");
                              ( "properties",
                                `Assoc
                                  [
                                    ("desc", `Assoc [ ("type", `String "string") ]);
                                    ("done", `Assoc [ ("type", `String "boolean") ]);
                                  ] );
                            ] );
                      ] );
                ] );
            ( "required",
              `List
                [
                  `String "room_id";
                  `String "quest_id";
                  `String "title";
                  `String "status";
                ] );
          ];
    };
    {
      name = "masc_trpg_world_event";
      description =
        "Record a global world state change (weather, political shift, catastrophe, etc.). \
         Required: room_id, event_type, description. \
         Optional: affected_areas (string array), severity (minor/major/catastrophic).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ( "event_type",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Type of world event (e.g. weather, political, disaster)" );
                      ] );
                  ("description", `Assoc [ ("type", `String "string") ]);
                  ( "affected_areas",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "severity",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "minor"; `String "major"; `String "catastrophic";
                            ] );
                      ] );
                ] );
            ( "required",
              `List
                [ `String "room_id"; `String "event_type"; `String "description" ] );
          ];
    };
    {
      name = "masc_trpg_preset_list";
      description =
        "List TRPG DM/world/character presets and game-usable agent skills from repo JSON SSOT.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("include_characters", `Assoc [ ("type", `String "boolean") ]);
                  ("include_skills", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    };
    {
      name = "masc_trpg_pool_generate";
      description =
        "Generate a playable character pool from presets. \
         Required: session_id. Optional: world_preset_id, dm_preset_id, pool_size, party_size, seed.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("world_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("pool_size", `Assoc [ ("type", `String "integer") ]);
                  ("party_size", `Assoc [ ("type", `String "integer") ]);
                  ("seed", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_trpg_party_select";
      description =
        "Select a party from generated pool and persist party.selected event. \
         Required: session_id, pool, selected_player_ids.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ( "pool",
                    `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "object") ]) ] );
                  ("selected_player_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ( "required",
              `List [ `String "session_id"; `String "pool"; `String "selected_player_ids" ] );
          ];
    };
    {
      name = "masc_trpg_session_start";
      description =
        "Start a TRPG session from DM/world presets and selected party. \
         Required: session_id. Optional: room_id, dm/world preset ids, dm_keeper, party, phase.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("world_preset_id", `Assoc [ ("type", `String "string") ]);
                  ("dm_keeper", `Assoc [ ("type", `String "string") ]);
                  ("party", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "object") ]) ]);
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                  ("force", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_spawn";
      description =
        "Spawn an actor entity in room state. \
         Required: room_id, actor_id. \
         Optional: role(dm|player|npc), name, archetype, persona, hp, max_hp, alive, traits, skills.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("role", `Assoc [ ("type", `String "string") ]);
                  ("name", `Assoc [ ("type", `String "string") ]);
                  ("archetype", `Assoc [ ("type", `String "string") ]);
                  ("persona", `Assoc [ ("type", `String "string") ]);
                  ("hp", `Assoc [ ("type", `String "integer") ]);
                  ("max_hp", `Assoc [ ("type", `String "integer") ]);
                  ("alive", `Assoc [ ("type", `String "boolean") ]);
                  ("traits", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("skills", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_claim";
      description =
        "Claim an actor lease for a keeper. \
         Required: room_id, actor_id, keeper_name. \
         Enforces one keeper -> one actor and denies claim when actor is dead.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "actor_id"; `String "keeper_name" ] );
          ];
    };
    {
      name = "masc_trpg_actor_release";
      description =
        "Release an actor lease held by a keeper. \
         Required: room_id, actor_id, keeper_name. Optional: reason.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List [ `String "room_id"; `String "actor_id"; `String "keeper_name" ] );
          ];
    };
    {
      name = "masc_trpg_intervention_submit";
      description =
        "Submit a human intervention to apply before next AI round run. \
         Required: room_id, intervention_type. Optional: scope, target_actor, expected_turn, payload.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("intervention_type", `Assoc [ ("type", `String "string") ]);
                  ("scope", `Assoc [ ("type", `String "string") ]);
                  ("target_actor", `Assoc [ ("type", `String "string") ]);
                  ("expected_turn", `Assoc [ ("type", `String "integer") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("payload", `Assoc [ ("type", `String "object") ]);
                ] );
            ("required", `List [ `String "room_id"; `String "intervention_type" ]);
          ];
    };
  ]

let ok_json json = (true, Yojson.Safe.to_string json)
let err msg = (false, msg)

let get_required_string args key =
  match args |> member key with
  | `String s ->
      let s = String.trim s in
      if s = "" then Error (Printf.sprintf "%s cannot be empty" key) else Ok s
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be string" key)

let get_optional_string args key =
  match args |> member key with
  | `String s ->
      let s = String.trim s in
      if s = "" then Ok None else Ok (Some s)
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be string" key)

let get_required_int args key =
  match args |> member key with
  | `Int i -> Ok i
  | `Intlit s -> (
      try Ok (int_of_string s)
      with _ -> Error (Printf.sprintf "%s must be int" key))
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be int" key)

let get_optional_int args key =
  match args |> member key with
  | `Int i -> Ok (Some i)
  | `Intlit s -> (
      try Ok (Some (int_of_string s))
      with _ -> Error (Printf.sprintf "%s must be int" key))
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be int" key)

let get_optional_float args key ~default =
  match args |> member key with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | `Intlit s -> (
      try Ok (float_of_string s)
      with _ -> Error (Printf.sprintf "%s must be number" key))
  | `Null -> Ok default
  | _ -> Error (Printf.sprintf "%s must be number" key)

let get_required_assoc args key =
  match args |> member key with
  | `Assoc fields -> Ok fields
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be object" key)

let get_required_list args key =
  match args |> member key with
  | `List xs -> Ok xs
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be array" key)

let get_optional_bool args key ~default =
  match args |> member key with
  | `Bool b -> Ok b
  | `Null -> Ok default
  | _ -> Error (Printf.sprintf "%s must be boolean" key)

let get_optional_object args key =
  match args |> member key with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be object" key)

let get_string_list_from_json = function
  | `List xs ->
      Ok
        (List.filter_map
           (function
             | `String s ->
                 let s = String.trim s in
                 if s = "" then None else Some s
             | _ -> None)
           xs)
  | _ -> Error "value must be string array"

let get_optional_string_list args key =
  match args |> member key with
  | `Null -> Ok []
  | `List _ as list_json -> get_string_list_from_json list_json
  | _ -> Error (Printf.sprintf "%s must be string array" key)

let dedupe_keep_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: tl ->
        if List.mem x seen then loop seen acc tl
        else loop (x :: seen) (x :: acc) tl
  in
  loop [] [] xs

let sanitize_room_id (s : string) =
  let s = String.trim s in
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let valid =
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '.' || c = '_' || c = '-'
    in
    if not valid then Bytes.set b i '-'
  done;
  let out = Bytes.to_string b in
  if out = "" then "session-default" else out

let validate_rule_module = function
  | "" | "dnd5e-lite" -> Ok ()
  | other -> Error (Printf.sprintf "unsupported rule_module: %s" other)

let validate_actor_role = function
  | "player" | "npc" | "dm" -> Ok ()
  | other -> Error (Printf.sprintf "role must be one of: player, npc, dm (got %s)" other)

let extract_config_from_events (events : Trpg_engine_event.t list) : Yojson.Safe.t =
  let rec loop = function
    | [] -> `Assoc []
    | (ev : Trpg_engine_event.t) :: tl -> (
        match ev.event_type with
        | Trpg_engine_event.Room_created -> (
            match ev.payload with
            | `Assoc fields -> (
                match List.assoc_opt "config" fields with
                | Some c -> c
                | None -> ev.payload)
            | _ -> `Assoc [])
        | _ -> loop tl)
  in
  loop events

let next_seq ~base_dir ~room_id =
  match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
  | Error e -> Error e
  | Ok events ->
      Ok
        (1
        + List.fold_left
            (fun acc (ev : Trpg_engine_event.t) -> max acc ev.seq)
            0 events)

let append_event ~base_dir ~room_id ~event_type ?actor_id ?ts ?seq ~payload () =
  let room_id = String.trim room_id in
  if room_id = "" then Error "room_id is required"
  else
    let seq_result =
      match seq with
      | Some s when s <= 0 -> Error "seq must be positive"
      | Some s -> Ok s
      | None -> next_seq ~base_dir ~room_id
    in
    match seq_result with
    | Error e -> Error e
    | Ok seq ->
        let ts = Option.value ~default:(Types.now_iso ()) ts in
        let event =
          Trpg_engine_event.make
            ~seq ~room_id ~ts ~event_type ?actor_id ~payload ()
        in
        (match Trpg_engine_store_sqlite.append_event ~base_dir ~event with
        | Ok () -> Ok event
        | Error e -> Error e)

let derive_state ~base_dir ~room_id ~rule_module =
  match validate_rule_module rule_module with
  | Error e -> Error e
  | Ok () -> (
      match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
      | Error e -> Error e
      | Ok events ->
          let config = extract_config_from_events events in
          let rule = (module Trpg_rule_dnd5e_lite : Trpg_rule.S) in
          let state = Trpg_engine_replay.derive_state ~rule ~config ~events in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("room_id", `String room_id);
                ("rule_module", `String rule_module);
                ("event_count", `Int (List.length events));
                ("state", state);
              ]))

let state_of_derived derived =
  match derived |> member "state" with `Null -> `Assoc [] | v -> v

let state_party_fields state =
  match state |> member "party" with
  | `Assoc fields -> fields
  | _ -> []

let actor_exists_in_state state actor_id =
  state_party_fields state |> List.mem_assoc actor_id

let actor_alive_in_state state actor_id =
  match state_party_fields state |> List.assoc_opt actor_id with
  | Some actor_json ->
      actor_json |> member "alive" |> to_bool_option |> Option.value ~default:true
  | None -> false

let state_actor_control_fields state =
  match state |> member "actor_control" with
  | `Assoc fields ->
      fields
      |> List.filter_map (function
           | actor_id, `String keeper_name ->
               let actor_id = String.trim actor_id in
               let keeper_name = String.trim keeper_name in
               if actor_id = "" || keeper_name = "" then None
               else Some (actor_id, keeper_name)
           | _ -> None)
  | _ -> []

let owner_for_actor state actor_id =
  state_actor_control_fields state |> List.assoc_opt actor_id

let actor_for_keeper state keeper_name =
  let keeper_key = normalize_keeper_name keeper_name in
  state_actor_control_fields state
  |> List.find_map (fun (actor_id, owner) ->
         if normalize_keeper_name owner = keeper_key then Some actor_id else None)

let read_state_turn derived =
  match state_of_derived derived |> member "turn" with
  | `Int i -> Ok i
  | _ -> Error "state.turn must be int"

let parse_player_keepers args =
  let ( let* ) = Result.bind in
  let* fields = get_required_assoc args "player_keepers" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (actor_id, `String keeper_name) :: tl ->
        let actor_id = String.trim actor_id in
        let keeper_name = String.trim keeper_name in
        if actor_id = "" then Error "player_keepers contains empty actor_id"
        else if keeper_name = "" then
          Error (Printf.sprintf "player_keepers.%s cannot be empty" actor_id)
        else loop ((actor_id, keeper_name) :: acc) tl
    | (actor_id, _) :: _ ->
        Error (Printf.sprintf "player_keepers.%s must be string" actor_id)
  in
  loop [] fields

let parse_keeper_reply keeper_json =
  match keeper_json |> member "reply" with
  | `String s ->
      let s = String.trim s in
      if s = "" then Error "keeper response reply is empty" else Ok s
  | _ -> Error "keeper response missing string field: reply"

type prompt_language = [ `Ko | `En ]

let prompt_language_of_string_opt = function
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "ko" | "kr" | "korean" -> `Ko
      | "en" | "english" -> `En
      | _ -> `Ko)
  | None -> `Ko

let build_keeper_prompt ~room_id ~phase ~turn ~role ~actor_id ~state_json ~lang =
  let role_s = role_to_string role in
  let state_text = Yojson.Safe.pretty_to_string state_json in
  match lang with
  | `Ko ->
      Printf.sprintf
        "TRPG 실행 요청입니다.\n\
         room_id=%s\n\
         phase=%s\n\
         turn=%d\n\
         role=%s\n\
         actor_id=%s\n\
         \n\
         visible_state_json:\n\
         %s\n\
         \n\
         반드시 한국어로 응답하세요. \
         일반 텍스트로 답하되 structured_action을 만들 수 있으면 \
         reply JSON 필드에 함께 포함하세요."
        room_id
        phase
        turn
        role_s
        actor_id
        state_text
  | `En ->
      Printf.sprintf
        "TRPG execution request.\n\
         room_id=%s\n\
         phase=%s\n\
         turn=%d\n\
         role=%s\n\
         actor_id=%s\n\
         \n\
         visible_state_json:\n\
         %s\n\
         \n\
         Respond in English. \
         Return your response as normal text. \
         If you can provide structured_action, include it in your reply JSON field."
        room_id
        phase
        turn
        role_s
        actor_id
        state_text

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

let append_timeout_and_unavailable_events
    ~base_dir
    ~room_id
    ~phase
    ~turn
    ~role
    ~actor_id
    ~keeper_name
    ~timeout_sec
    =
  let ( let* ) = Result.bind in
  let timeout_payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("timeout_sec", `Float timeout_sec);
        ("stage", `String "masc_keeper_msg");
      ]
  in
  let* timeout_event =
    append_event
      ~base_dir
      ~room_id
      ~event_type:Trpg_engine_event.Turn_timeout
      ~actor_id
      ~payload:timeout_payload
      ()
  in
  let unavailable_payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("reason", `String "timeout");
      ]
  in
  let* unavailable_event =
    append_event
      ~base_dir
      ~room_id
      ~event_type:Trpg_engine_event.Keeper_unavailable
      ~actor_id
      ~payload:unavailable_payload
      ()
  in
  Ok [ timeout_event; unavailable_event ]

let append_unavailable_event
    ~base_dir ~room_id ~phase ~turn ~role ~actor_id ~keeper_name ~reason () =
  let payload =
    `Assoc
      [
        ("phase", `String phase);
        ("turn", `Int turn);
        ("role", `String (role_to_string role));
        ("actor_id", `String actor_id);
        ("keeper", `String keeper_name);
        ("reason", `String reason);
      ]
  in
  append_event
    ~base_dir
    ~room_id
    ~event_type:Trpg_engine_event.Keeper_unavailable
    ~actor_id
    ~payload
    ()

let append_keeper_reply_event
    ~base_dir
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
    ~base_dir
    ~room_id
    ~event_type
    ~actor_id
    ~payload
    ()

let handle_dice_roll ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* action = get_required_string args "action" in
    let* stat_value = get_required_int args "stat_value" in
    let* dc = get_required_int args "dc" in
    let* raw_opt = get_optional_int args "raw_d20" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* raw_d20 =
      match raw_opt with
      | Some i ->
          if i < 1 || i > 20 then Error "raw_d20 must be between 1 and 20" else Ok i
      | None -> Ok (1 + Random.int 20)
    in
    let bonus = Trpg_rule_dnd5e_lite.stat_bonus stat_value in
    let total = raw_d20 + bonus in
    let c = Trpg_rule_dnd5e_lite.classify_roll ~raw_d20 ~total in
    let payload =
      `Assoc
        [
          ("actor_id", `String actor_id);
          ("action", `String action);
          ("stat_value", `Int stat_value);
          ("dc", `Int dc);
          ("raw_d20", `Int raw_d20);
          ("bonus", `Int bonus);
          ("total", `Int total);
          ("tier", `String (Trpg_rule_dnd5e_lite.roll_tier_to_string c.tier));
          ("label", `String c.label);
          ("passed", `Bool c.passed);
        ]
    in
    let* event =
      append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Dice_rolled
        ~actor_id
        ~payload
        ()
    in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg_engine_event.to_yojson event);
          ( "roll",
            `Assoc
              [
                ("raw_d20", `Int raw_d20);
                ("bonus", `Int bonus);
                ("total", `Int total);
                ("dc", `Int dc);
                ("passed", `Bool c.passed);
                ("label", `String c.label);
              ] );
          ("state", state_of_derived derived);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_turn_advance ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* phase_opt = get_optional_string args "phase" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* () =
      match phase_opt with
      | None -> Ok ()
      | Some p -> (
          match Trpg_engine_types.phase_of_string p with
          | Ok _ -> Ok ()
          | Error e -> Error e)
    in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    let* current_turn = read_state_turn derived in
    let next_turn = max 1 (current_turn + 1) in
    let* turn_event =
      append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Turn_started
        ~payload:(`Assoc [ ("turn", `Int next_turn) ])
        ()
    in
    let* phase_event_opt =
      match phase_opt with
      | None -> Ok None
      | Some p ->
          let* ev =
            append_event
              ~base_dir
              ~room_id
              ~event_type:Trpg_engine_event.Phase_changed
              ~payload:(`Assoc [ ("phase", `String p) ])
              ()
          in
          Ok (Some ev)
    in
    let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
    let events_json =
      [ Some turn_event; phase_event_opt ]
      |> List.filter_map (fun x -> x)
      |> List.map Trpg_engine_event.to_yojson
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("turn", `Int next_turn);
          ("events", `List events_json);
          ("state", state_of_derived next_derived);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_stream ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* after_seq_opt = get_optional_int args "after_seq" in
    let after_seq = Option.value ~default:0 after_seq_opt in
    let* event_type_opt = get_optional_string args "event_type" in
    let* parsed_event_type =
      match event_type_opt with
      | None -> Ok None
      | Some s -> (
          match Trpg_engine_event.event_type_of_string s with
          | Ok et -> Ok (Some et)
          | Error _ -> Error (Printf.sprintf "invalid event_type: %s" s))
    in
    let* events =
      if after_seq > 0 then
        Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq
      else Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
    in
    let events =
      match parsed_event_type with
      | None -> events
      | Some et ->
          List.filter
            (fun (ev : Trpg_engine_event.t) -> ev.event_type = et)
            events
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("stream", `Bool true);
          ("room_id", `String room_id);
          ("after_seq", `Int after_seq);
          ("count", `Int (List.length events));
          ("events", `List (List.map Trpg_engine_event.to_yojson events));
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let resolve_dm_preset catalog dm_preset_id_opt =
  match dm_preset_id_opt with
  | Some preset_id -> (
      match Trpg_preset_store.find_dm_preset catalog ~id:preset_id with
      | Some preset -> Ok preset
      | None -> Error (Printf.sprintf "unknown dm_preset_id: %s" preset_id))
  | None -> (
      match catalog.Trpg_preset_store.dm_presets with
      | head :: _ -> Ok head
      | [] -> Error "no dm presets available")

let resolve_world_preset catalog world_preset_id_opt =
  match world_preset_id_opt with
  | Some preset_id -> (
      match Trpg_preset_store.find_world_preset catalog ~id:preset_id with
      | Some preset -> Ok preset
      | None -> Error (Printf.sprintf "unknown world_preset_id: %s" preset_id))
  | None -> (
      match catalog.Trpg_preset_store.world_presets with
      | head :: _ -> Ok head
      | [] -> Error "no world presets available")

let shuffle_with_seed ~seed xs =
  let arr = Array.of_list xs in
  let rng = Random.State.make [| seed |] in
  for i = Array.length arr - 1 downto 1 do
    let j = Random.State.int rng (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done;
  Array.to_list arr

let generate_pool_members ~catalog ~pool_size ~seed =
  let templates =
    shuffle_with_seed ~seed catalog.Trpg_preset_store.character_presets
  in
  match templates with
  | [] -> Error "no character presets available"
  | _ ->
      let rec build idx acc =
        if idx > pool_size then List.rev acc
        else
          let base =
            List.nth templates ((idx - 1) mod List.length templates)
          in
          let actor_id = Printf.sprintf "p%02d" idx in
          let member : pool_member =
            {
              actor_id;
              name = base.name;
              archetype = base.archetype;
              persona = base.persona;
              traits = base.traits;
              skill_ids = base.skill_ids;
              keeper_name = None;
              source_preset_id = base.id;
            }
          in
          build (idx + 1) (member :: acc)
      in
      Ok (build 1 [])

let default_party_from_catalog catalog party_size =
  let capped = max 1 (min party_size 8) in
  match generate_pool_members ~catalog ~pool_size:capped ~seed:42 with
  | Ok members -> members
  | Error _ -> []

let assoc_put key value fields =
  (key, value) :: List.remove_assoc key fields

let append_pending_interventions ~base_dir ~room_id ~phase ~turn =
  let ( let* ) = Result.bind in
  let* events = Trpg_engine_store_sqlite.read_events ~base_dir ~room_id in
  let pending = derive_pending_interventions events in
  let rec loop applied_payloads applied_events = function
    | [] -> Ok (List.rev applied_payloads, List.rev applied_events)
    | (_, intervention_id, payload) :: tl ->
        let applied_payload =
          match payload with
          | `Assoc fields ->
              `Assoc
                (fields
                |> assoc_put "status" (`String "applied")
                |> assoc_put "applied_phase" (`String phase)
                |> assoc_put "applied_turn" (`Int turn)
                |> assoc_put "intervention_id" (`String intervention_id))
          | _ ->
              `Assoc
                [
                  ("intervention_id", `String intervention_id);
                  ("status", `String "applied");
                  ("applied_phase", `String phase);
                  ("applied_turn", `Int turn);
                ]
        in
        let* ev =
          append_event ~base_dir ~room_id
            ~event_type:Trpg_engine_event.Intervention_applied
            ~payload:applied_payload ()
        in
        loop (applied_payload :: applied_payloads) (ev :: applied_events) tl
  in
  loop [] [] pending

let handle_preset_list ctx args : result =
  let ( let* ) = Result.bind in
  let include_characters =
    get_optional_bool args "include_characters" ~default:true
  in
  let include_skills = get_optional_bool args "include_skills" ~default:true in
  let result_json =
    let* include_characters = include_characters in
    let* include_skills = include_skills in
    let* catalog = Trpg_preset_store.load_catalog ~base_dir:ctx.config.base_path in
    let payload =
      `Assoc
        [
          ("ok", `Bool true);
          ( "dm_presets",
            `List
              (List.map
                 Trpg_preset_store.dm_preset_to_yojson
                 catalog.dm_presets) );
          ( "world_presets",
            `List
              (List.map
                 Trpg_preset_store.world_preset_to_yojson
                 catalog.world_presets) );
          ( "character_presets",
            if include_characters then
              `List
                (List.map
                   Trpg_preset_store.character_preset_to_yojson
                   catalog.character_presets)
            else `List [] );
          ( "skills",
            if include_skills then
              `List
                (List.map
                   Trpg_preset_store.skill_to_yojson
                   catalog.skills)
            else `List [] );
        ]
    in
    Ok payload
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_pool_generate ctx args : result =
  let ( let* ) = Result.bind in
  let result_json =
    let* session_id = get_required_string args "session_id" in
    let* world_preset_id = get_optional_string args "world_preset_id" in
    let* dm_preset_id = get_optional_string args "dm_preset_id" in
    let* pool_size_opt = get_optional_int args "pool_size" in
    let* party_size_opt = get_optional_int args "party_size" in
    let* seed_opt = get_optional_int args "seed" in
    let pool_size = Option.value ~default:8 pool_size_opt |> max 2 |> min 16 in
    let party_size =
      Option.value ~default:4 party_size_opt
      |> max 1 |> min 8 |> min pool_size
    in
    let seed = Option.value ~default:42 seed_opt in
    let* catalog = Trpg_preset_store.load_catalog ~base_dir:ctx.config.base_path in
    let* dm_preset = resolve_dm_preset catalog dm_preset_id in
    let* world_preset = resolve_world_preset catalog world_preset_id in
    let* pool = generate_pool_members ~catalog ~pool_size ~seed in
    let suggested =
      pool
      |> List.map (fun (m : pool_member) -> m.actor_id)
      |> List.filteri (fun i _ -> i < party_size)
    in
    let pool_id =
      let material =
        Printf.sprintf "%s|%s|%s|%d|%d|%d" session_id dm_preset.id world_preset.id
          pool_size party_size seed
      in
      "pool-" ^ Digest.to_hex (Digest.string material)
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("session_id", `String session_id);
          ("pool_id", `String pool_id);
          ("dm_preset", Trpg_preset_store.dm_preset_to_yojson dm_preset);
          ("world_preset", Trpg_preset_store.world_preset_to_yojson world_preset);
          ("pool", `List (List.map pool_member_to_yojson pool));
          ("suggested_party_ids", json_of_strings suggested);
          ("party_size", `Int party_size);
          ("pool_size", `Int pool_size);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_party_select ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* session_id = get_required_string args "session_id" in
    let* room_id_opt = get_optional_string args "room_id" in
    let room_id =
      room_id_opt |> Option.value ~default:(room_id_for_session session_id)
    in
    let* pool_json = get_required_list args "pool" in
    let* selected_ids_json = get_required_list args "selected_player_ids" in
    let* pool = pool_members_of_json_list pool_json in
    let* selected_ids = get_string_list_from_json (`List selected_ids_json) in
    let selected_ids = dedupe_keep_order selected_ids in
    if selected_ids = [] then Error "selected_player_ids must not be empty"
    else
      let pool_by_id : (string, pool_member) Hashtbl.t = Hashtbl.create 32 in
      List.iter
        (fun (m : pool_member) -> Hashtbl.replace pool_by_id m.actor_id m)
        pool;
      let rec pick acc = function
        | [] -> Ok (List.rev acc)
        | actor_id :: tl -> (
            match Hashtbl.find_opt pool_by_id actor_id with
            | Some m -> pick (m :: acc) tl
            | None ->
                Error
                  (Printf.sprintf
                     "selected_player_ids contains unknown actor_id: %s"
                     actor_id))
      in
      let* selected_party = pick [] selected_ids in
      let payload =
        `Assoc
          [
            ("session_id", `String session_id);
            ("room_id", `String room_id);
            ("selected_player_ids", json_of_strings selected_ids);
            ("party", `List (List.map pool_member_to_yojson selected_party));
          ]
      in
      let* event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Party_selected ~payload ()
      in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("session_id", `String session_id);
            ("party_count", `Int (List.length selected_party));
            ("party", `List (List.map pool_member_to_yojson selected_party));
            ("event", Trpg_engine_event.to_yojson event);
          ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_session_start ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* session_id = get_required_string args "session_id" in
    let* room_id_opt = get_optional_string args "room_id" in
    let room_id =
      room_id_opt |> Option.value ~default:(room_id_for_session session_id)
    in
    let* dm_preset_id = get_optional_string args "dm_preset_id" in
    let* world_preset_id = get_optional_string args "world_preset_id" in
    let* dm_keeper_opt = get_optional_string args "dm_keeper" in
    let dm_keeper = dm_keeper_opt |> Option.value ~default:"dm-keeper" in
    let* phase_opt = get_optional_string args "phase" in
    let phase = phase_opt |> Option.value ~default:"briefing" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* force = get_optional_bool args "force" ~default:false in
    let* () =
      match Trpg_engine_types.phase_of_string phase with
      | Ok _ -> Ok ()
      | Error e -> Error e
    in
    let* () = validate_rule_module rule_module in
    let* catalog = Trpg_preset_store.load_catalog ~base_dir in
    let* dm_preset = resolve_dm_preset catalog dm_preset_id in
    let* world_preset = resolve_world_preset catalog world_preset_id in
    let* party =
      match args |> member "party" with
      | `List xs when xs <> [] -> pool_members_of_json_list xs
      | _ ->
          let fallback_party = default_party_from_catalog catalog 4 in
          if fallback_party = [] then Error "party is required (no character presets available)"
          else Ok fallback_party
    in
    let* existing_events =
      Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
    in
    let has_existing_bootstrap_event =
      List.exists
        (fun (ev : Trpg_engine_event.t) ->
          match ev.event_type with
          | Trpg_engine_event.Room_created
          | Trpg_engine_event.Room_started
          | Trpg_engine_event.Session_started ->
              true
          | _ -> false)
        existing_events
    in
    let* () =
      if (not force) && has_existing_bootstrap_event then
        Error
          (Printf.sprintf
             "room_id is already bootstrapped; pass force=true to append anyway: %s"
             room_id)
      else Ok ()
    in
    let room_created_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("rule_module", `String rule_module);
          ("scenario_id", `String world_preset.id);
          ("dm_preset_id", `String dm_preset.id);
          ("world_preset_id", `String world_preset.id);
          ( "config",
            `Assoc
              [
                ("party", party_config party);
                ("world", world_config ~preset:world_preset);
                ("dm", dm_config ~preset:dm_preset ~dm_keeper);
              ] );
        ]
    in
    let* room_created =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Room_created
        ~actor_id:ctx.agent_name ~payload:room_created_payload ()
    in
    let session_started_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("room_id", `String room_id);
          ("dm_keeper", `String dm_keeper);
          ("dm_preset_id", `String dm_preset.id);
          ("world_preset_id", `String world_preset.id);
          ("party_count", `Int (List.length party));
          ("mode", `String "ai_auto_with_human_nudge");
        ]
    in
    let* session_started =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Session_started
        ~actor_id:ctx.agent_name ~payload:session_started_payload ()
    in
    let party_selected_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("selected_player_ids", json_of_strings (List.map (fun p -> p.actor_id) party));
          ("party", `List (List.map pool_member_to_yojson party));
        ]
    in
    let* party_selected =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Party_selected
        ~actor_id:ctx.agent_name ~payload:party_selected_payload ()
    in
    let* phase_event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Phase_changed
        ~payload:(`Assoc [ ("phase", `String phase) ])
        ()
    in
    let* room_started =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Room_started
        ~payload:(`Assoc [ ("phase", `String phase) ])
        ()
    in
    let player_keepers_json =
      `Assoc
        (List.map
           (fun (member_ : pool_member) ->
             let keeper =
               member_.keeper_name
               |> Option.value ~default:(Printf.sprintf "pk-%s" member_.actor_id)
             in
             (member_.actor_id, `String keeper))
           party)
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("session_id", `String session_id);
          ("phase", `String phase);
          ("dm_keeper", `String dm_keeper);
          ("dm_preset", Trpg_preset_store.dm_preset_to_yojson dm_preset);
          ("world_preset", Trpg_preset_store.world_preset_to_yojson world_preset);
          ("party", `List (List.map pool_member_to_yojson party));
          ( "round_run_template",
            `Assoc
              [
                ("room_id", `String room_id);
                ("dm_keeper", `String dm_keeper);
                ("player_keepers", player_keepers_json);
                ("phase", `String "round");
              ] );
          ( "events",
            `List
              [
                Trpg_engine_event.to_yojson room_created;
                Trpg_engine_event.to_yojson session_started;
                Trpg_engine_event.to_yojson party_selected;
                Trpg_engine_event.to_yojson phase_event;
                Trpg_engine_event.to_yojson room_started;
              ] );
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let actor_payload_from_spawn_args args ~actor_id =
  let ( let* ) = Result.bind in
  let* role_opt = get_optional_string args "role" in
  let role = Option.value ~default:"player" role_opt |> String.lowercase_ascii in
  let* () = validate_actor_role role in
  let* name_opt = get_optional_string args "name" in
  let* archetype_opt = get_optional_string args "archetype" in
  let* persona_opt = get_optional_string args "persona" in
  let* hp_opt = get_optional_int args "hp" in
  let* max_hp_opt = get_optional_int args "max_hp" in
  let* alive = get_optional_bool args "alive" ~default:true in
  let* traits = get_optional_string_list args "traits" in
  let* skills = get_optional_string_list args "skills" in
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
            ("hp", `Int hp);
            ("max_hp", `Int max_hp);
            ("alive", `Bool alive);
            ("traits", json_of_strings traits);
            ("skills", json_of_strings skills);
            ("inventory", `List []);
          ]
      in
      Ok actor_json

let handle_actor_spawn ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    let state = state_of_derived derived in
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
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Actor_spawned
          ~actor_id ~payload ()
      in
      let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
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

let handle_actor_claim ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name = get_required_string args "keeper_name" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    let state = state_of_derived derived in
    if not (actor_exists_in_state state actor_id) then
      Error (Printf.sprintf "unknown actor_id: %s" actor_id)
    else if not (actor_alive_in_state state actor_id) then
      Error (Printf.sprintf "actor is not alive: %s" actor_id)
    else
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
                append_event ~base_dir ~room_id
                  ~event_type:Trpg_engine_event.Actor_claimed
                  ~actor_id ~payload ()
              in
              let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
              Ok
                (`Assoc
                  [
                    ("ok", `Bool true);
                    ("room_id", `String room_id);
                    ("actor_id", `String actor_id);
                    ("keeper_name", `String keeper_name);
                    ("status", `String "claimed");
                    ("event", Trpg_engine_event.to_yojson event);
                    ("state", state_of_derived next_derived);
                  ]) )
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_actor_release ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name = get_required_string args "keeper_name" in
    let* reason_opt = get_optional_string args "reason" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
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
          append_event ~base_dir ~room_id
            ~event_type:Trpg_engine_event.Actor_released
            ~actor_id ~payload ()
        in
        let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
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

let handle_intervention_submit ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* session_id_opt = get_optional_string args "session_id" in
    let* intervention_type = get_required_string args "intervention_type" in
    let* scope_opt = get_optional_string args "scope" in
    let scope = scope_opt |> Option.value ~default:"turn.before" in
    let* target_actor = get_optional_string args "target_actor" in
    let* expected_turn = get_optional_int args "expected_turn" in
    let* reason = get_optional_string args "reason" in
    let* payload_opt = get_optional_object args "payload" in
    let intervention_id =
      Printf.sprintf "intrv-%Ld"
        (Int64.of_float (Unix.gettimeofday () *. 1000.0))
    in
    let payload =
      `Assoc
        [
          ("intervention_id", `String intervention_id);
          ("intervention_type", `String intervention_type);
          ("scope", `String scope);
          ("session_id", Option.fold ~none:`Null ~some:(fun v -> `String v) session_id_opt);
          ("target_actor", Option.fold ~none:`Null ~some:(fun v -> `String v) target_actor);
          ("expected_turn", Option.fold ~none:`Null ~some:(fun v -> `Int v) expected_turn);
          ("reason", Option.fold ~none:`Null ~some:(fun v -> `String v) reason);
          ("payload", Option.value ~default:(`Assoc []) payload_opt);
          ("status", `String "pending");
          ("submitted_by", `String ctx.agent_name);
        ]
    in
    let* event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Intervention_submitted
        ~actor_id:ctx.agent_name ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("intervention_id", `String intervention_id);
          ("status", `String "pending");
          ("event", Trpg_engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_round_run ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* dm_keeper_raw = get_required_string args "dm_keeper" in
    let dm_keeper = String.trim dm_keeper_raw in
    let* player_keepers = parse_player_keepers args in
    let* timeout_sec = get_optional_float args "timeout_sec" ~default:30.0 in
    if timeout_sec <= 0.0 then Error "timeout_sec must be > 0"
    else if dm_keeper = "" then Error "dm_keeper cannot be empty"
    else
      let* rule_opt = get_optional_string args "rule_module" in
      let* phase_opt = get_optional_string args "phase" in
      let* lang_opt = get_optional_string args "lang" in
      let* require_claim = get_optional_bool args "require_claim" ~default:false in
      let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
      let phase = Option.value ~default:"round" phase_opt in
      let prompt_lang = prompt_language_of_string_opt lang_opt in
      let* () =
        match ctx.keeper_call with
        | Some _ -> Ok ()
        | None -> Error "keeper_call is not available in this runtime"
      in
      let* () = validate_rule_module rule_module in
      let* () =
        match Trpg_engine_types.phase_of_string phase with
        | Ok _ -> Ok ()
        | Error e -> Error e
      in
      let* () = validate_unique_keeper_assignments ~dm_keeper ~player_keepers in
      with_keeper_reservation
        ~keepers:(dm_keeper :: List.map snd player_keepers)
        (fun () ->
      let* derived = derive_state ~base_dir ~room_id ~rule_module in
      let state = state_of_derived derived in
      let* turn_before = read_state_turn derived in
      let next_turn = max 1 (turn_before + 1) in

      let* phase_event =
        append_event
          ~base_dir
          ~room_id
          ~event_type:Trpg_engine_event.Phase_changed
          ~payload:(`Assoc [ ("phase", `String phase) ])
          ()
      in
      let* interventions_applied, intervention_events =
        append_pending_interventions ~base_dir ~room_id ~phase ~turn:turn_before
      in
      let state_for_prompt =
        inject_interventions_into_state state interventions_applied
      in

      let appended_events = ref (phase_event :: intervention_events) in
      let statuses = ref [] in
      let success_count = ref 0 in
      let unavailable_count = ref 0 in
      let timeout_count = ref 0 in

      let process_one ~role ~actor_id ~keeper_name =
        let record_unavailable_status ~status ~error =
          let* unavailable_event =
            append_unavailable_event
              ~base_dir
              ~room_id
              ~phase
              ~turn:turn_before
              ~role
              ~actor_id
              ~keeper_name
              ~reason:error
              ()
          in
          unavailable_count := !unavailable_count + 1;
          appended_events := !appended_events @ [ unavailable_event ];
          statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String (role_to_string role));
                ("keeper", `String keeper_name);
                ("status", `String status);
                ("error", `String error);
              ]
            :: !statuses;
          Ok ()
        in
        let lease_check =
          match role with
          | `Dm -> Ok ()
          | `Player -> (
              match owner_for_actor state actor_id with
              | Some owner when normalize_keeper_name owner <> normalize_keeper_name keeper_name ->
                  Error
                    (Printf.sprintf
                       "actor lease mismatch: actor_id=%s owner=%s requested=%s"
                       actor_id owner keeper_name)
              | None when require_claim ->
                  Error
                    (Printf.sprintf
                       "actor must be claimed before round_run: actor_id=%s"
                       actor_id)
              | _ -> Ok () )
        in
        match lease_check with
        | Error lease_error -> record_unavailable_status ~status:"lease_denied" ~error:lease_error
        | Ok () ->
        let prompt =
          build_keeper_prompt
            ~room_id
            ~phase
            ~turn:turn_before
            ~role
            ~actor_id
            ~state_json:state_for_prompt
            ~lang:prompt_lang
        in
        match call_keeper ctx ~name:keeper_name ~message:prompt ~timeout_sec with
        | `Timeout ->
            let* timeout_events =
              append_timeout_and_unavailable_events
                ~base_dir
                ~room_id
                ~phase
                ~turn:turn_before
                ~role
                ~actor_id
                ~keeper_name
                ~timeout_sec
            in
            timeout_count := !timeout_count + 1;
            unavailable_count := !unavailable_count + 1;
            appended_events := !appended_events @ timeout_events;
            statuses :=
              `Assoc
                [
                  ("actor_id", `String actor_id);
                  ("role", `String (role_to_string role));
                  ("keeper", `String keeper_name);
                  ("status", `String "timeout");
                  ("timeout_sec", `Float timeout_sec);
                ]
              :: !statuses;
            Ok ()
        | `Error keeper_error ->
            record_unavailable_status ~status:"unavailable" ~error:keeper_error
        | `Ok keeper_json -> (
            match parse_keeper_reply keeper_json with
            | Error parse_error ->
                record_unavailable_status ~status:"invalid_response" ~error:parse_error
            | Ok reply ->
                let* reply_event =
                  append_keeper_reply_event
                    ~base_dir
                    ~room_id
                    ~phase
                    ~turn:turn_before
                    ~role
                    ~actor_id
                    ~keeper_name
                    ~reply
                in
                success_count := !success_count + 1;
                appended_events := !appended_events @ [ reply_event ];
                statuses :=
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("role", `String (role_to_string role));
                      ("keeper", `String keeper_name);
                      ("status", `String "ok");
                      ("reply", `String reply);
                    ]
                  :: !statuses;
                Ok () )
      in

      let* () = process_one ~role:`Dm ~actor_id:"dm" ~keeper_name:dm_keeper in
      let* () =
        List.fold_left
          (fun acc (actor_id, keeper_name) ->
            let* () = acc in
            process_one ~role:`Player ~actor_id ~keeper_name)
          (Ok ())
          player_keepers
      in
      let* turn_event =
        append_event
          ~base_dir
          ~room_id
          ~event_type:Trpg_engine_event.Turn_started
          ~payload:(`Assoc [ ("turn", `Int next_turn) ])
          ()
      in
      appended_events := !appended_events @ [ turn_event ];
      let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
      let statuses = List.rev !statuses in
      let events_json = List.map Trpg_engine_event.to_yojson !appended_events in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("phase", `String phase);
            ("turn_before", `Int turn_before);
            ("turn_after", `Int next_turn);
            ("timeout_sec", `Float timeout_sec);
            ("statuses", `List statuses);
            ("interventions_applied", `List interventions_applied);
            ( "summary",
              `Assoc
                [
                  ("participants", `Int (1 + List.length player_keepers));
                  ("successes", `Int !success_count);
                  ("timeouts", `Int !timeout_count);
                  ("unavailable", `Int !unavailable_count);
                  ("interventions", `Int (List.length interventions_applied));
                ] );
            ("events", `List events_json);
            ("state", state_of_derived next_derived);
          ]))
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_scene_transition ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* from_scene = get_required_string args "from_scene" in
    let* to_scene = get_required_string args "to_scene" in
    let* trigger = get_optional_string args "trigger" in
    let* narrative_hook = get_optional_string args "narrative_hook" in
    let payload =
      `Assoc
        [
          ("from_scene", `String from_scene);
          ("to_scene", `String to_scene);
          ( "trigger",
            match trigger with Some t -> `String t | None -> `Null );
          ( "narrative_hook",
            match narrative_hook with Some h -> `String h | None -> `Null );
        ]
    in
    let* event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Scene_transition ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg_engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_quest_update ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* quest_id = get_required_string args "quest_id" in
    let* title = get_required_string args "title" in
    let* status = get_required_string args "status" in
    let* () =
      match status with
      | "active" | "completed" | "failed" -> Ok ()
      | _ -> Error "status must be one of: active, completed, failed"
    in
    let objectives =
      match args |> member "objectives" with
      | `List xs -> `List xs
      | _ -> `List []
    in
    let payload =
      `Assoc
        [
          ("quest_id", `String quest_id);
          ("title", `String title);
          ("status", `String status);
          ("objectives", objectives);
        ]
    in
    let* event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Quest_update ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg_engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_world_event ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* evt_type = get_required_string args "event_type" in
    let* description = get_required_string args "description" in
    let* severity_opt = get_optional_string args "severity" in
    let severity = Option.value ~default:"minor" severity_opt in
    let* () =
      match severity with
      | "minor" | "major" | "catastrophic" -> Ok ()
      | _ -> Error "severity must be one of: minor, major, catastrophic"
    in
    let affected_areas =
      match args |> member "affected_areas" with
      | `List xs -> `List xs
      | _ -> `List []
    in
    let payload =
      `Assoc
        [
          ("event_type", `String evt_type);
          ("description", `String description);
          ("affected_areas", affected_areas);
          ("severity", `String severity);
        ]
    in
    let* event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.World_event ~payload ()
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg_engine_event.to_yojson event);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_trpg_dice_roll" -> Some (handle_dice_roll ctx args)
  | "masc_trpg_turn_advance" -> Some (handle_turn_advance ctx args)
  | "masc_trpg_stream" -> Some (handle_stream ctx args)
  | "masc_trpg_preset_list" -> Some (handle_preset_list ctx args)
  | "masc_trpg_pool_generate" -> Some (handle_pool_generate ctx args)
  | "masc_trpg_party_select" -> Some (handle_party_select ctx args)
  | "masc_trpg_session_start" -> Some (handle_session_start ctx args)
  | "masc_trpg_actor_spawn" -> Some (handle_actor_spawn ctx args)
  | "masc_trpg_actor_claim" -> Some (handle_actor_claim ctx args)
  | "masc_trpg_actor_release" -> Some (handle_actor_release ctx args)
  | "masc_trpg_intervention_submit" -> Some (handle_intervention_submit ctx args)
  | "masc_trpg_round_run" -> Some (handle_round_run ctx args)
  | "masc_trpg_scene_transition" -> Some (handle_scene_transition ctx args)
  | "masc_trpg_quest_update" -> Some (handle_quest_update ctx args)
  | "masc_trpg_world_event" -> Some (handle_world_event ctx args)
  | _ -> None
