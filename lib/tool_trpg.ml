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
    - masc_trpg_actor_update
    - masc_trpg_actor_delete
    - masc_trpg_actor_claim
    - masc_trpg_actor_release
    - masc_trpg_intervention_submit
*)

open Yojson.Safe.Util

type result = bool * string

type keeper_call_result = [ `Ok of Yojson.Safe.t | `Timeout | `Error of string ]
type keeper_probe_result = [ `Ok | `Error of string ]
type dm_voice_emit_result = (Yojson.Safe.t, string) Stdlib.result

type context = {
  config : Room.config;
  agent_name : string;
  keeper_call :
    (name:string -> message:string -> timeout_sec:float -> keeper_call_result)
    option;
  keeper_probe : (name:string -> keeper_probe_result) option;
  dm_voice_emit :
    (agent_id:string ->
     message:string ->
     provider:string option ->
     dm_voice_emit_result)
    option;
}

type trpg_role = [ `Dm | `Player ]

let role_to_string = function `Dm -> "dm" | `Player -> "player"

let normalize_keeper_name (s : string) : string =
  s |> String.trim |> String.lowercase_ascii

let clamp_int low high value =
  if value < low then low
  else if value > high then high
  else value

let trpg_keeper_timeout_sec_default = 0.0
let trpg_keeper_timeout_sec_env = "MASC_TRPG_KEEPER_TIMEOUT_SEC"

let trpg_keeper_timeout_sec () =
  match Sys.getenv_opt trpg_keeper_timeout_sec_env with
  | Some raw -> (
      match float_of_string_opt (String.trim raw) with
      | Some value when value > 0.0 -> value
      | _ -> trpg_keeper_timeout_sec_default)
  | None -> trpg_keeper_timeout_sec_default

let resolve_keeper_timeout_sec ~timeout_sec ~participant_count : float =
  let participant_count = max 1 participant_count in
  let per_actor_budget = timeout_sec /. float_of_int participant_count in
  let base = min timeout_sec per_actor_budget in
  let floor_sec = trpg_keeper_timeout_sec () in
  if floor_sec <= 0.0 then base else min timeout_sec (max floor_sec base)

let unique_nonempty_keepers (keepers : string list) : string list =
  keepers
  |> List.map String.trim
  |> List.filter (fun k -> k <> "")
  |> List.sort_uniq String.compare

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

let keeper_preflight ctx ~(keepers : string list) : (unit, string) Stdlib.result =
  match ctx.keeper_probe with
  | None -> Ok ()
  | Some probe ->
      let failures =
        unique_nonempty_keepers keepers
        |> List.filter_map (fun keeper_name ->
               match probe ~name:keeper_name with
               | `Ok -> None
               | `Error raw_reason ->
                   let reason =
                     let trimmed = String.trim raw_reason in
                     if trimmed = "" then "unavailable" else trimmed
                   in
                   Some (Printf.sprintf "%s=%s" keeper_name reason))
      in
      if failures = [] then Ok ()
      else
        Error
          (Printf.sprintf "keeper preflight failed: %s"
             (String.concat "; " failures))

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
         Optional: phase(default round), rule_module(default dnd5e-lite), timeout_sec(default 90), lang(ko|en), dm_persona(grim_gothic|tactical_irony|heroic_epic), require_claim(boolean), local_fallback(boolean).";
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
                  ("dm_persona", `Assoc [ ("type", `String "string") ]);
                  ("require_claim", `Assoc [ ("type", `String "boolean") ]);
                  ("lang", `Assoc [ ("type", `String "string") ]);
                  ( "local_fallback",
                    `Assoc [ ("type", `String "boolean") ] );
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
         Required: session_id. Optional: room_id, dm/world preset ids, world_contract_id, canon_strict, dm_keeper, party, phase.";
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
                  ("world_contract_id", `Assoc [ ("type", `String "string") ]);
                  ("canon_strict", `Assoc [ ("type", `String "boolean") ]);
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
         Optional: role(dm|player|npc), name, archetype, persona, hp, max_hp, alive, traits, skills, inventory.";
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
                  ("inventory", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_update";
      description =
        "Update an existing actor entity in room state. \
         Required: room_id, actor_id. \
         Optional: role(dm|player|npc), name, archetype, persona, hp, max_hp, alive, traits, skills, inventory.";
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
                  ("inventory", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_actor_delete";
      description =
        "Delete an actor entity from room state and release its lease. \
         Required: room_id, actor_id. Optional: reason.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
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
      name = "masc_trpg_join_eligibility";
      description =
        "Check whether an actor is eligible for mid-session join under hard gate policy. \
         Required: room_id, actor_id. Optional: keeper_name, rule_module.";
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
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id"; `String "actor_id" ]);
          ];
    };
    {
      name = "masc_trpg_mid_join_request";
      description =
        "Request a hard-gated mid-session join (round-boundary only + contribution threshold). \
         Required: room_id, actor_id, keeper_name. \
         Optional: role, name, archetype, persona, hp, max_hp, traits, skills, inventory, rule_module.";
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
                  ("role", `Assoc [ ("type", `String "string") ]);
                  ("name", `Assoc [ ("type", `String "string") ]);
                  ("archetype", `Assoc [ ("type", `String "string") ]);
                  ("persona", `Assoc [ ("type", `String "string") ]);
                  ("hp", `Assoc [ ("type", `String "integer") ]);
                  ("max_hp", `Assoc [ ("type", `String "integer") ]);
                  ("traits", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("skills", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("inventory", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
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

let get_optional_string_list_option args key =
  match args |> member key with
  | `Null -> Ok None
  | `List _ as list_json ->
      let ( let* ) = Result.bind in
      let* xs = get_string_list_from_json list_json in
      Ok (Some xs)
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

let mid_join_min_score_default = 3
let mid_join_min_score_env = "TRPG_MID_JOIN_MIN_SCORE"

let mid_join_min_score () =
  match Sys.getenv_opt mid_join_min_score_env with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some n when n > 0 -> n
      | _ -> mid_join_min_score_default)
  | None -> mid_join_min_score_default

type join_gate_state = {
  phase_open : bool;
  min_points : int;
  window : string;
}

let join_gate_of_state state =
  let gate = state |> member "join_gate" in
  let phase_open =
    match gate |> member "phase_open" with
    | `Bool v -> v
    | _ -> true
  in
  let min_points =
    match gate |> member "min_points" with
    | `Int v when v > 0 -> v
    | _ -> mid_join_min_score ()
  in
  let window =
    match gate |> member "window" with
    | `String v when String.trim v <> "" -> String.trim v
    | _ -> "round_boundary_only"
  in
  { phase_open; min_points; window }

let actor_role_in_state state actor_id =
  match state_party_fields state |> List.assoc_opt actor_id with
  | Some actor_json -> (
      match actor_json |> member "role" with
      | `String role when String.trim role <> "" ->
          String.lowercase_ascii (String.trim role)
      | _ -> "player")
  | None -> "player"

let contribution_score_in_state state actor_id =
  match state |> member "contribution_ledger" |> member actor_id |> member "score" with
  | `Int v -> v
  | _ -> 0

type keeper_bonus_eval = {
  bonus : int;
  source : string;
  reason : string option;
  warning : string option;
}

let parse_keeper_bonus json =
  let raw =
    match json |> member "bonus" with
    | `Int i -> Some i
    | `Float f -> Some (int_of_float f)
    | _ -> None
  in
  let reason =
    match json |> member "reason" with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  match raw with
  | Some v -> Some (clamp_int (-1) 1 v, reason)
  | None -> None

let evaluate_keeper_bonus ctx ~keeper_name ~room_id ~actor_id ~server_score
    ~required_points =
  match ctx.keeper_call with
  | None ->
      {
        bonus = 0;
        source = "deterministic_fallback";
        reason = None;
        warning = Some "keeper runtime unavailable";
      }
  | Some keeper_call -> (
      let message =
        Printf.sprintf
          "You are evaluating a TRPG mid-join request.\n\
           Return strict JSON: {\"bonus\": -1|0|1, \"reason\": \"short\"}.\n\
           room_id=%s actor_id=%s server_score=%d required_points=%d\n\
           Rules: +1 only if strong positive contribution trend; -1 if disruptive risk; else 0."
          room_id actor_id server_score required_points
      in
      match keeper_call ~name:keeper_name ~message ~timeout_sec:(trpg_keeper_timeout_sec ()) with
      | `Ok payload -> (
          match parse_keeper_bonus payload with
          | Some (bonus, reason) ->
              { bonus; source = "keeper_judge"; reason; warning = None }
          | None ->
              {
                bonus = 0;
                source = "deterministic_fallback";
                reason = None;
                warning = Some "keeper returned unparsable bonus";
              })
      | `Timeout ->
          {
            bonus = 0;
            source = "deterministic_fallback";
            reason = None;
            warning = Some "keeper judge timeout";
          }
      | `Error err ->
          {
            bonus = 0;
            source = "deterministic_fallback";
            reason = None;
            warning = Some (Printf.sprintf "keeper judge error: %s" err);
          })

let contribution_actor_id_of_event (event : Trpg_engine_event.t) =
  let payload = event.payload in
  let from_payload =
    match payload |> member "actor_id" with
    | `String v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  match from_payload with
  | Some actor_id -> Some actor_id
  | None ->
      Option.bind event.actor_id (fun v ->
          let trimmed = String.trim v in
          if trimmed = "" then None else Some trimmed)

let contribution_add score_tbl reasons_tbl ~actor_id ~delta ~reason =
  let prev = Hashtbl.find_opt score_tbl actor_id |> Option.value ~default:0 in
  let next = clamp_int (-10) 50 (prev + delta) in
  Hashtbl.replace score_tbl actor_id next;
  let reasons = Hashtbl.find_opt reasons_tbl actor_id |> Option.value ~default:[] in
  let next_reasons =
    if String.trim reason = "" then reasons else
      let appended = reasons @ [ reason ] in
      let len = List.length appended in
      if len <= 8 then appended else
        let rec drop n xs =
          if n <= 0 then xs
          else
            match xs with
            | [] -> []
            | _ :: tl -> drop (n - 1) tl
        in
        drop (len - 8) appended
  in
  Hashtbl.replace reasons_tbl actor_id next_reasons

let contribution_snapshot_from_events events =
  let score_tbl = Hashtbl.create 32 in
  let reasons_tbl = Hashtbl.create 32 in
  List.iter
    (fun (event : Trpg_engine_event.t) ->
      let payload = event.payload in
      match event.event_type with
      | Trpg_engine_event.Turn_action_resolved -> (
          match contribution_actor_id_of_event event with
          | Some actor_id ->
              contribution_add score_tbl reasons_tbl ~actor_id ~delta:2
                ~reason:"turn.action.resolved +2"
          | None -> ())
      | Trpg_engine_event.Intervention_applied -> (
          let actor_id =
            match payload |> member "target_actor" with
            | `String v when String.trim v <> "" -> Some (String.trim v)
            | _ -> contribution_actor_id_of_event event
          in
          match actor_id with
          | Some id ->
              contribution_add score_tbl reasons_tbl ~actor_id:id ~delta:1
                ~reason:"intervention.applied +1"
          | None -> ())
      | Trpg_engine_event.Dice_rolled -> (
          match contribution_actor_id_of_event event with
          | Some actor_id ->
              let passed =
                match payload |> member "passed" with
                | `Bool b -> b
                | _ -> false
              in
              let delta = if passed then 1 else -1 in
              let reason =
                if passed then "dice.rolled(pass) +1"
                else "dice.rolled(fail) -1"
              in
              contribution_add score_tbl reasons_tbl ~actor_id ~delta ~reason
          | None -> ())
      | _ -> ())
    events;
  (score_tbl, reasons_tbl)

let contribution_for_actor_from_events events actor_id =
  let score_tbl, reasons_tbl = contribution_snapshot_from_events events in
  let score = Hashtbl.find_opt score_tbl actor_id |> Option.value ~default:0 in
  let reasons = Hashtbl.find_opt reasons_tbl actor_id |> Option.value ~default:[] in
  (score, reasons)

let append_memory_signal_event ~base_dir ~room_id ~event_tier ~importance_score
    ~summary_ko ~summary_en ~entity_refs =
  let payload =
    `Assoc
      [
        ("event_tier", `String event_tier);
        ("importance_score", `Int (clamp_int 0 100 importance_score));
        ("summary_ko", `String summary_ko);
        ("summary_en", `String summary_en);
        ("entity_refs", `Assoc entity_refs);
      ]
  in
  append_event ~base_dir ~room_id
    ~event_type:Trpg_engine_event.Memory_signal
    ~payload ()

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

let string_of_session_outcome = function
  | Victory -> "victory"
  | Defeat -> "defeat"
  | Draw -> "draw"

let summary_of_session_outcome = function
  | Victory -> "Victory condition met."
  | Defeat -> "Defeat condition met."
  | Draw -> "Draw condition met."

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

let load_world_contract_catalog ~base_dir : world_contract_catalog =
  let path = world_contracts_path ~base_dir in
  if not (Sys.file_exists path) then default_world_contract_catalog
  else
    match Yojson.Safe.from_file path with
    | exception _ -> default_world_contract_catalog
    | json -> (
        match parse_world_contract_catalog_json json with
        | Ok catalog -> catalog
        | Error _ -> default_world_contract_catalog)

let find_world_contract (catalog : world_contract_catalog) ~id =
  catalog.contracts
  |> List.find_opt (fun (contract : world_contract) ->
         String.equal contract.id id)

let resolve_world_contract_for_session ~base_dir ~world_preset_id
    ~world_contract_id_opt :
    (world_contract, string) Stdlib.result =
  let catalog = load_world_contract_catalog ~base_dir in
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

let resolve_end_rules_for_room ~base_dir ~(events : Trpg_engine_event.t list) :
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
              match Trpg_preset_store.load_catalog ~base_dir with
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

let evaluate_session_outcome ~end_rules ~(state : Yojson.Safe.t) ~dm_reply :
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
  let max_turn_reached =
    let turn =
      match state |> member "turn" with
      | `Int n -> n
      | _ -> 0
    in
    turn >= end_rules.Trpg_preset_store.max_turn
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

let evaluate_canon_check ~base_dir ~state ~events ~dm_reply : canon_check =
  match canon_contract_ref_from_state state with
  | None -> canon_check_disabled
  | Some (contract_id, strict) -> (
      let catalog = load_world_contract_catalog ~base_dir in
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

let append_canon_check_observability_events ~base_dir ~room_id ~turn ~phase
    ~(check : canon_check) =
  let ( let* ) = Result.bind in
  if not check.enabled || check.status = "pass" then Ok []
  else
    let severity = if check.status = "fail" then "major" else "minor" in
    let contract_id = check.contract_id |> Option.value ~default:"unknown" in
    let description =
      Printf.sprintf "Canon check %s for contract=%s (violations=%d warnings=%d)"
        check.status contract_id
        (List.length check.violations)
        (List.length check.warnings)
    in
    let payload =
      let strings_json xs = `List (List.map (fun value -> `String value) xs) in
      `Assoc
        [
          ("event_type", `String "canon.check");
          ("description", `String description);
          ("severity", `String severity);
          ("turn", `Int turn);
          ("phase", `String phase);
          ("contract_id", `String contract_id);
          ("strict", `Bool check.strict);
          ("status", `String check.status);
          ("violations", strings_json check.violations);
          ("warnings", strings_json check.warnings);
        ]
    in
    let* world_event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.World_event
        ~actor_id:"dm" ~payload ()
    in
    let importance_score = if check.status = "fail" then 84 else 61 in
    let memory_tier = if check.status = "fail" then "long" else "mid" in
    let* memory_event =
      append_memory_signal_event ~base_dir ~room_id ~event_tier:memory_tier
        ~importance_score
        ~summary_ko:
          (Printf.sprintf "캐논 검사 %s: %s" check.status contract_id)
        ~summary_en:
          (Printf.sprintf "Canon check %s: %s" check.status contract_id)
        ~entity_refs:
          [
            ("source", `String "canon_check");
            ("contract_id", `String contract_id);
            ("status", `String check.status);
            ("strict", `Bool check.strict);
            ("turn", `Int turn);
            ("phase", `String phase);
            ("violation_count", `Int (List.length check.violations));
            ("warning_count", `Int (List.length check.warnings));
          ]
    in
    Ok [ world_event; memory_event ]

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
         if ev.event_type = Trpg_engine_event.Session_outcome then Some ev.payload
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

let action_type_of_string = function
  | "attack" -> Some Attack
  | "defend" | "defense" -> Some Defend
  | "heal" -> Some Heal
  | "investigate" -> Some Investigate
  | "social" | "talk" | "persuade" -> Some Social
  | "explore" | "search" | "look" -> Some Explore
  | "magic" | "spell" | "cast" -> Some Magic
  | "use_item" | "item" -> Some UseItem
  | "set_flag" | "flag" -> Some SetFlag
  | "scene_transition" | "scene" | "move" -> Some SceneTransition
  | "quest_update" | "quest" -> Some QuestUpdate
  | _ -> None

let string_of_action_type = function
  | Attack -> "attack"
  | Defend -> "defend"
  | Heal -> "heal"
  | Investigate -> "investigate"
  | Social -> "social"
  | Explore -> "explore"
  | Magic -> "magic"
  | UseItem -> "use_item"
  | SetFlag -> "set_flag"
  | SceneTransition -> "scene_transition"
  | QuestUpdate -> "quest_update"

let memory_tier_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "short" -> Some Memory_short
  | "mid" | "medium" -> Some Memory_mid
  | "long" -> Some Memory_long
  | _ -> None

let string_of_memory_tier = function
  | Memory_short -> "short"
  | Memory_mid -> "mid"
  | Memory_long -> "long"

let memory_tier_rank = function
  | Memory_short -> 1
  | Memory_mid -> 2
  | Memory_long -> 3

let max_memory_tier a b =
  if memory_tier_rank a >= memory_tier_rank b then a else b

let parse_structured_memory_hint (sa_json : Yojson.Safe.t) :
    structured_memory_hint option =
  match sa_json |> member "memory_hint" with
  | `Assoc _ as hint_json ->
      let tier_opt =
        match hint_json |> member "tier" with
        | `String raw -> memory_tier_of_string raw
        | _ -> None
      in
      tier_opt
      |> Option.map (fun requested_tier ->
             let importance_score =
               match hint_json |> member "importance_score" with
               | `Int n -> Some (clamp_int 0 100 n)
               | `Float n -> Some (clamp_int 0 100 (int_of_float n))
               | _ -> None
             in
             let reason =
               match hint_json |> member "reason" with
               | `String raw ->
                   let value = String.trim raw in
                   if value = "" then None else Some value
               | _ -> None
             in
             { requested_tier; importance_score; reason })
  | _ -> None

let extract_structured_action_json_from_reply_line line :
    (Yojson.Safe.t option, string) Stdlib.result =
  let trimmed = String.trim line in
  if trimmed = "" then Ok None
  else
    let lowered = String.lowercase_ascii trimmed in
    let prefix = "structured_action:" in
    if not (starts_with lowered prefix) then Ok None
    else
      let payload =
        String.sub trimmed (String.length prefix)
          (String.length trimmed - String.length prefix)
        |> String.trim
      in
      if payload = "" then Error "structured_action payload is empty"
      else
        match Yojson.Safe.from_string payload with
        | `Assoc fields when fields <> [] -> Ok (Some (`Assoc fields))
        | `Assoc _ -> Error "structured_action object is empty"
        | _ -> Error "structured_action payload must be JSON object"
        | exception Yojson.Json_error e ->
            Error (Printf.sprintf "invalid structured_action json: %s" e)

let extract_structured_action_json_from_reply (reply : string) :
    (Yojson.Safe.t option, string) Stdlib.result =
  let rec loop = function
    | [] -> Ok None
    | line :: tl -> (
        match extract_structured_action_json_from_reply_line line with
        | Ok None -> loop tl
        | Ok (Some _ as found) -> Ok found
        | Error e -> Error e)
  in
  loop (String.split_on_char '\n' reply)

let extract_structured_action_json (keeper_json : Yojson.Safe.t) :
    (Yojson.Safe.t option, string) Stdlib.result =
  match keeper_json |> member "structured_action" with
  | `Assoc fields when fields <> [] -> Ok (Some (`Assoc fields))
  | `Assoc _ -> Error "structured_action object is empty"
  | `Null -> (
      match first_nonempty_string_field [ "reply"; "content"; "text"; "message" ] keeper_json with
      | Some reply -> extract_structured_action_json_from_reply reply
      | None -> Ok None)
  | _ -> Error "structured_action must be an object"

let extract_structured_action (keeper_json : Yojson.Safe.t) :
    structured_action option =
  match extract_structured_action_json keeper_json with
  | Error _ -> None
  | Ok None -> None
  | Ok (Some sa) ->
      let type_str =
        match sa |> member "type" with
        | `String s -> String.lowercase_ascii (String.trim s)
        | _ -> ""
      in
      (match action_type_of_string type_str with
      | None -> None
      | Some sa_type ->
          let get_string key =
            match sa |> member key with
            | `String s when String.trim s <> "" -> Some (String.trim s)
            | _ -> None
          in
          Some
            {
              sa_type;
              target_id = get_string "target_id";
              description =
                (match get_string "description" with Some d -> d | None -> "");
              flag_key = get_string "flag_key";
              scene = get_string "scene";
              quest_info = get_string "quest_info";
              memory_hint = parse_structured_memory_hint sa;
              raw_payload = sa;
            })

let is_player_action_type = function
  | Attack | Defend | Heal | Investigate | Social | Explore | Magic | UseItem ->
      true
  | SetFlag | SceneTransition | QuestUpdate -> false

let is_dm_action_type = function
  | SetFlag | SceneTransition | QuestUpdate -> true
  | Attack | Defend | Heal | Investigate | Social | Explore | Magic | UseItem ->
      false

type structured_action_validation_error =
  [ `Schema of string | `Rule of string ]

let validate_structured_action_for_role ~role (sa : structured_action) :
    (structured_action, structured_action_validation_error) Stdlib.result =
  let ( let* ) = Result.bind in
  let actor_role = role_to_string role in
  let action_name = string_of_action_type sa.sa_type in
  let require_nonempty name = function
    | Some v when String.trim v <> "" -> Ok (String.trim v)
    | _ -> Error (`Schema (Printf.sprintf "%s is required for %s" name action_name))
  in
  let* () =
    match role with
    | `Player ->
        if is_player_action_type sa.sa_type then Ok ()
        else
          Error
            (`Rule
               (Printf.sprintf
                  "action_type=%s is not allowed for role=%s"
                  action_name actor_role))
    | `Dm ->
        if is_dm_action_type sa.sa_type then Ok ()
        else
          Error
            (`Rule
               (Printf.sprintf
                  "action_type=%s is not allowed for role=%s"
                  action_name actor_role))
  in
  let* description =
    let text = String.trim sa.description in
    if text = "" then
      Error (`Schema "description is required for structured_action")
    else Ok text
  in
  let* flag_key =
    match sa.sa_type with
    | SetFlag -> require_nonempty "flag_key" sa.flag_key |> Result.map (fun v -> Some v)
    | _ -> Ok sa.flag_key
  in
  let* scene =
    match sa.sa_type with
    | SceneTransition ->
        require_nonempty "scene" sa.scene |> Result.map (fun v -> Some v)
    | _ -> Ok sa.scene
  in
  let* quest_info =
    match sa.sa_type with
    | QuestUpdate ->
        require_nonempty "quest_info" sa.quest_info
        |> Result.map (fun v -> Some v)
    | _ -> Ok sa.quest_info
  in
  Ok { sa with description; flag_key; scene; quest_info }

let parse_and_validate_structured_action ~role (keeper_json : Yojson.Safe.t) :
    (structured_action, structured_action_validation_error) Stdlib.result =
  let ( let* ) = Result.bind in
  let* sa_json_opt =
    match extract_structured_action_json keeper_json with
    | Ok v -> Ok v
    | Error e -> Error (`Schema e)
  in
  let* sa =
    match sa_json_opt with
    | None -> Error (`Schema "structured_action is missing")
    | Some _ -> (
        match extract_structured_action keeper_json with
        | Some parsed -> Ok parsed
        | None ->
            Error (`Schema "structured_action type is unknown or malformed"))
  in
  validate_structured_action_for_role ~role sa

let string_of_structured_action_validation_error = function
  | `Schema msg -> msg
  | `Rule msg -> msg

let structured_action_error_kind = function
  | `Schema _ -> "schema"
  | `Rule _ -> "rule"

let structured_action_error_message = function
  | `Schema msg -> msg
  | `Rule msg -> msg

let detect_combat_semantic (text : string) : combat_semantic option =
  let lowered = String.lowercase_ascii text in
  let has_any keywords =
    List.exists (fun keyword -> contains_substring lowered keyword) keywords
  in
  if
    has_any
      [
        "attack";
        "strike";
        "slash";
        "stab";
        "shoot";
        "assault";
        "공격";
        "타격";
        "베기";
        "사격";
        "돌격";
      ]
  then Some Combat_attack_intent
  else if
    has_any
      [
        "defend";
        "defensive";
        "guard";
        "block";
        "parry";
        "shield";
        "dodge";
        "evade";
        "방어";
        "엄폐";
        "회피";
        "가드";
      ]
  then Some Combat_defense_intent
  else None

(* Server-side narrative inference: extract action type from LLM narrative
   when the explicit structured_action JSON format is missing.
   Ordered by specificity — more specific matches first to avoid
   "heal" matching before "attack" in "heals after the attack". *)
let infer_action_type_from_narrative ~(role : [ `Player | `Dm ])
    (text : string) : structured_action option =
  let lowered = String.lowercase_ascii text in
  let has_any keywords =
    List.exists (fun keyword -> contains_substring lowered keyword) keywords
  in
  let make_sa sa_type ?(flag_key : string option) ?(scene : string option)
      ?(quest_info : string option) desc =
    {
      sa_type;
      target_id = None;
      description = desc;
      flag_key;
      scene;
      quest_info;
      memory_hint = None;
      raw_payload =
        `Assoc
          [
            ("type", `String (string_of_action_type sa_type));
            ("description", `String desc);
            ("inferred", `Bool true);
          ];
    }
  in
  let truncate_desc s =
    let max_len = 120 in
    if String.length s <= max_len then s
    else String.sub s 0 max_len ^ "..."
  in
  let desc = truncate_desc (String.trim text) in
  match role with
  | `Player ->
      (* Ordered: specific first, generic last *)
      if has_any [ "cast"; "spell"; "magic"; "incantation"; "주문"; "마법"; "시전" ]
      then Some (make_sa Magic desc)
      else if
        has_any [ "heal"; "cure"; "bandage"; "potion"; "치료"; "회복"; "붕대"; "포션" ]
      then Some (make_sa Heal desc)
      else if
        has_any
          [
            "examine"; "inspect"; "investigate"; "search"; "look for"; "조사";
            "살펴"; "탐색"; "확인";
          ]
      then Some (make_sa Investigate desc)
      else if
        has_any
          [
            "talk"; "persuade"; "negotiate"; "diplomacy"; "convince"; "대화";
            "설득"; "협상"; "말을 건";
          ]
      then Some (make_sa Social desc)
      else if
        has_any
          [ "use"; "drink"; "equip"; "consume"; "activate"; "사용"; "마시"; "장착" ]
      then Some (make_sa UseItem desc)
      else if
        has_any [ "explore"; "wander"; "travel"; "move to"; "탐험"; "이동"; "걸어" ]
      then Some (make_sa Explore desc)
      else if
        has_any
          [
            "attack"; "strike"; "slash"; "stab"; "shoot"; "hit"; "swing";
            "공격"; "타격"; "베기"; "사격"; "돌격"; "찌르";
          ]
      then Some (make_sa Attack desc)
      else if
        has_any
          [
            "defend"; "block"; "parry"; "shield"; "dodge"; "evade"; "방어";
            "막기"; "회피"; "가드";
          ]
      then Some (make_sa Defend desc)
      else if desc <> "" then
        (* Keep round progression when keeper narration is skill-name-heavy
           but still semantically actionable. *)
        Some (make_sa Attack desc)
      else None
  | `Dm ->
      if
        has_any
          [
            "discover"; "found"; "reveal"; "unlock"; "milestone"; "발견";
            "드러나"; "밝혀"; "획득";
          ]
      then Some (make_sa SetFlag ~flag_key:"story.inferred" desc)
      else if
        has_any
          [
            "enter"; "arrive"; "move to"; "travel to"; "new area"; "들어서";
            "도착"; "이동하"; "새로운 장소"; "방으로";
          ]
      then Some (make_sa SceneTransition ~scene:desc desc)
      else if
        has_any
          [
            "quest"; "mission"; "objective"; "task"; "의뢰"; "임무"; "퀘스트";
            "목표";
          ]
      then Some (make_sa QuestUpdate ~quest_info:desc desc)
      else if desc <> "" then
        Some (make_sa SetFlag ~flag_key:"story.inferred" desc)
      else None

let role_from_actor_json actor_json =
  match actor_json |> member "role" with
  | `String s ->
      let normalized = String.lowercase_ascii (String.trim s) in
      if normalized = "" then "player" else normalized
  | _ -> "player"

let is_actor_alive actor_json =
  match actor_json |> member "alive" with
  | `Bool b -> b
  | _ -> (
      match actor_json |> member "hp" with
      | `Int hp -> hp > 0
      | _ -> true)

let party_fields_of_state state =
  match state |> member "party" with
  | `Assoc fields -> fields
  | _ -> []

let actor_json_of_state state actor_id =
  party_fields_of_state state |> List.assoc_opt actor_id

let choose_attack_target_id ~state ~actor_id =
  let attacker_role =
    match actor_json_of_state state actor_id with
    | Some actor_json -> role_from_actor_json actor_json
    | None -> "player"
  in
  let turn =
    match state |> member "turn" with
    | `Int n when n > 0 -> n
    | _ -> 1
  in
  let live_actors =
    party_fields_of_state state
    |> List.filter (fun (aid, actor_json) ->
           aid <> actor_id && is_actor_alive actor_json)
  in
  let choose_from_candidates salt candidates =
    match candidates with
    | [] -> None
    | _ ->
        let len = List.length candidates in
        let seed = Hashtbl.hash (actor_id ^ ":" ^ salt) in
        let offset = (if seed < 0 then -seed else seed) mod len in
        let idx = ((turn - 1) + offset) mod len in
        Some (fst (List.nth candidates idx))
  in
  let pick pred salt =
    let candidates =
      live_actors
      |> List.filter (fun (_, actor_json) -> pred (role_from_actor_json actor_json))
    in
    choose_from_candidates salt candidates
  in
  if attacker_role = "npc" then
    match pick (fun role -> role <> "npc" && role <> "dm") "npc-primary" with
    | Some actor -> Some actor
    | None -> (
        match pick (fun role -> role <> "npc") "npc-fallback" with
        | Some actor -> Some actor
        | None -> choose_from_candidates "npc-any" live_actors)
  else
    match pick (fun role -> role = "npc") "player-primary" with
    | Some actor -> Some actor
    | None -> choose_from_candidates "player-any" live_actors

(* --- NPC Bestiary -------------------------------------------------------- *)

type npc_template = {
  npc_name : string;
  archetype : string;
  persona : string;
  traits : string list;
  skills : string list;
  base_hp : int;
  damage_min : int;
  damage_max : int;
  attack_narrations : string list;
}

let npc_bestiary : npc_template array =
  [|
    (* -- Skirmishers: low-mid HP, fast, flanking damage -- *)
    {
      npc_name = "Hollow Stalker";
      archetype = "predator-skirmisher";
      persona = "A relentless shadow prowling the frontline.";
      traits = [ "aggressive"; "opportunistic" ];
      skills = [ "shadow_claw"; "lunge" ];
      base_hp = 12;
      damage_min = 2;
      damage_max = 5;
      attack_narrations =
        [
          "그림자 발톱이 허공을 갈랐다.";
          "어둠 속에서 빠르게 돌진하며 할퀸다.";
          "잔영만 남기며 옆구리를 노린다.";
        ];
    };
    {
      npc_name = "Feral Wraith";
      archetype = "phantom-skirmisher";
      persona = "A tormented spirit lashing out at the living.";
      traits = [ "ethereal"; "relentless" ];
      skills = [ "spectral_rend"; "phase_strike" ];
      base_hp = 10;
      damage_min = 3;
      damage_max = 5;
      attack_narrations =
        [
          "원혼의 손길이 살갗을 파고든다.";
          "차가운 기운이 뼈를 스친다.";
          "실체 없는 팔이 허공에서 뻗어 나온다.";
        ];
    };
    {
      npc_name = "Thorn Crawler";
      archetype = "plant-skirmisher";
      persona = "A twisted vine creature creeping along the walls.";
      traits = [ "patient"; "ensnaring" ];
      skills = [ "vine_lash"; "thorn_spray" ];
      base_hp = 14;
      damage_min = 2;
      damage_max = 4;
      attack_narrations =
        [
          "가시 덩굴이 발목을 감아 조인다.";
          "날카로운 가시가 사방으로 흩뿌려진다.";
          "땅 아래에서 뿌리가 솟아올라 찌른다.";
        ];
    };
    (* -- Brutes: high HP, heavy damage, slow -- *)
    {
      npc_name = "Ironclad Golem";
      archetype = "construct-brute";
      persona = "An ancient automaton animated by forgotten runes.";
      traits = [ "armored"; "relentless" ];
      skills = [ "slam"; "iron_fist" ];
      base_hp = 22;
      damage_min = 4;
      damage_max = 7;
      attack_narrations =
        [
          "강철 주먹이 대지를 울리며 내려찍는다.";
          "묵직한 팔이 바람을 가르며 휘둘러진다.";
          "녹슨 관절이 삐걱대며 돌진한다.";
        ];
    };
    {
      npc_name = "Savage Ogre";
      archetype = "beast-brute";
      persona = "A towering mass of muscle and rage.";
      traits = [ "brutal"; "dim-witted" ];
      skills = [ "crush"; "roar" ];
      base_hp = 20;
      damage_min = 4;
      damage_max = 8;
      attack_narrations =
        [
          "거대한 곤봉이 머리 위에서 내리꽂힌다.";
          "분노에 찬 포효와 함께 돌진한다.";
          "땅을 흔드는 발걸음으로 짓밟으려 한다.";
        ];
    };
    {
      npc_name = "Plague Bearer";
      archetype = "toxic-brute";
      persona = "A bloated horror oozing contagion.";
      traits = [ "toxic"; "resilient" ];
      skills = [ "noxious_slam"; "bile_burst" ];
      base_hp = 18;
      damage_min = 3;
      damage_max = 6;
      attack_narrations =
        [
          "부패한 손아귀로 움켜쥐며 독을 퍼뜨린다.";
          "역겨운 담즙이 터져 나와 사방을 적신다.";
          "오염된 팔이 느릿하지만 정확하게 내려친다.";
        ];
    };
    (* -- Casters: low HP, high variance damage, magic -- *)
    {
      npc_name = "Void Weaver";
      archetype = "dark-caster";
      persona = "A hooded figure channeling abyssal energy.";
      traits = [ "cunning"; "fragile" ];
      skills = [ "void_bolt"; "shadow_bind" ];
      base_hp = 8;
      damage_min = 3;
      damage_max = 8;
      attack_narrations =
        [
          "허공에서 검은 빛줄기가 쏟아진다.";
          "어둠의 파동이 영혼을 잠식한다.";
          "심연의 에너지가 손끝에서 폭발한다.";
        ];
    };
    {
      npc_name = "Flame Disciple";
      archetype = "fire-caster";
      persona = "A zealot wreathed in living fire.";
      traits = [ "fanatical"; "volatile" ];
      skills = [ "fireball"; "ignite" ];
      base_hp = 9;
      damage_min = 3;
      damage_max = 7;
      attack_narrations =
        [
          "불꽃이 손바닥에서 소용돌이치며 발사된다.";
          "뜨거운 화염이 대지를 태우며 번져간다.";
          "작열하는 불덩이가 포물선을 그리며 날아온다.";
        ];
    };
    {
      npc_name = "Frost Warden";
      archetype = "ice-caster";
      persona = "A sentinel of eternal winter.";
      traits = [ "methodical"; "cold" ];
      skills = [ "frost_spike"; "frozen_grasp" ];
      base_hp = 10;
      damage_min = 2;
      damage_max = 7;
      attack_narrations =
        [
          "서릿발이 땅을 타고 발밑을 얼린다.";
          "얼음 창이 허공에서 결정화되어 꽂힌다.";
          "차가운 손길이 사지를 마비시킨다.";
        ];
    };
    (* -- Elites: balanced, multiple skills, mid-late game -- *)
    {
      npc_name = "Shadow Knight";
      archetype = "dark-elite";
      persona = "A fallen warrior wielding cursed steel.";
      traits = [ "disciplined"; "relentless"; "armored" ];
      skills = [ "cursed_slash"; "dark_shield"; "riposte" ];
      base_hp = 18;
      damage_min = 3;
      damage_max = 6;
      attack_narrations =
        [
          "저주받은 검날이 암흑빛을 뿜으며 베어낸다.";
          "묵직한 반격이 방패 너머로 날아온다.";
          "어둠의 기사가 냉정하게 칼을 내리친다.";
        ];
    };
    {
      npc_name = "Chimera Hound";
      archetype = "beast-elite";
      persona = "A multi-headed beast fused by dark alchemy.";
      traits = [ "ferocious"; "unpredictable" ];
      skills = [ "triple_bite"; "acid_spit"; "pounce" ];
      base_hp = 16;
      damage_min = 3;
      damage_max = 7;
      attack_narrations =
        [
          "세 개의 머리가 동시에 이빨을 드러낸다.";
          "산성 침이 갑옷을 녹이며 튀어 오른다.";
          "거대한 몸이 도약하며 짓누른다.";
        ];
    };
    {
      npc_name = "Bone Colossus";
      archetype = "undead-elite";
      persona = "A towering skeleton assembled from a hundred corpses.";
      traits = [ "imposing"; "resilient"; "slow" ];
      skills = [ "bone_crush"; "skeletal_rain"; "reassemble" ];
      base_hp = 24;
      damage_min = 4;
      damage_max = 7;
      attack_narrations =
        [
          "거대한 뼈 주먹이 천천히, 그러나 확실하게 내려온다.";
          "부러진 뼈 파편이 쏟아져 내린다.";
          "해골 거인이 한 발 내딛으며 대지가 울린다.";
        ];
    };
  |]

(** Difficulty tier for NPC selection based on game progression. *)
type difficulty_tier = Early | Mid | Late

(** Tier pools: which bestiary indices are available at each game stage. *)
let early_pool = [| 0; 1; 2 |]
let mid_pool = [| 0; 1; 2; 3; 4; 5; 6; 7; 8 |]
let late_pool = [| 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11 |]

(** Determine difficulty tier from turn number. *)
let tier_of_turn turn =
  let t = if turn < 0 then -turn else turn in
  if t <= 5 then Early
  else if t <= 15 then Mid
  else Late

(** Select an NPC template deterministically based on turn number.
    Restricts the pool based on game progression:
    - Early (turns 1-5): skirmishers only (indices 0-2)
    - Mid (turns 6-15): +brutes, +casters (indices 0-8)
    - Late (turns 16+): all including elites (indices 0-11) *)
let select_npc_template ~turn =
  let abs_turn = if turn < 0 then -turn else turn in
  let pool =
    match tier_of_turn turn with
    | Early -> early_pool
    | Mid -> mid_pool
    | Late -> late_pool
  in
  let idx = abs_turn mod Array.length pool in
  npc_bestiary.(pool.(idx))

(** Select an NPC template with explicit tier override.
    Allows callers to force a specific difficulty tier regardless of turn. *)
let select_npc_template_with_tier ~turn ~tier =
  let abs_turn = if turn < 0 then -turn else turn in
  let pool =
    match tier with
    | Early -> early_pool
    | Mid -> mid_pool
    | Late -> late_pool
  in
  let idx = abs_turn mod Array.length pool in
  npc_bestiary.(pool.(idx))

(** Scale NPC HP based on game progression.
    Early (turn 1-5): base_hp,
    Mid (turn 6-15): base_hp * 1.5,
    Late (turn 16+): base_hp * 2.0 *)
let scale_hp ~turn ~base_hp =
  if turn <= 5 then base_hp
  else if turn <= 15 then base_hp + (base_hp / 2)
  else base_hp * 2

(** Archetype-aware deterministic damage.
    When ~damage_range is provided, uses that range instead of flat 2-4.
    Range is (min, max) inclusive. *)
let deterministic_damage ~turn ~actor_id ?(damage_range = (2, 4)) () =
  let min_d, max_d = damage_range in
  let hash = Hashtbl.hash (actor_id ^ ":" ^ string_of_int turn) in
  let span = max_d - min_d + 1 in
  let bucket = (if hash < 0 then -hash else hash) mod span in
  min_d + bucket

(** Pick a counterattack narration for an NPC based on its template and turn. *)
let npc_attack_narration ~turn ~npc_template =
  let narrations = npc_template.attack_narrations in
  let len = List.length narrations in
  if len = 0 then "잔존한 적이 반격해 전열을 흔든다."
  else
    let idx = (if turn < 0 then -turn else turn) mod len in
    List.nth narrations idx

(** Find a bestiary template by NPC name.  Falls back to the turn-based
    selection if no exact match is found (e.g. legacy data). *)
let find_npc_template_by_name name =
  Array.to_seq npc_bestiary
  |> Seq.find (fun t -> t.npc_name = name)

(** Skill effect variants for NPC archetype abilities. *)
type skill_effect =
  | BonusDamage of int
  | DoubleDamage
  | MultiTarget
  | SelfHeal of int
  | NoSkill

(** Check if a string contains a given substring. *)
let string_contains ~haystack ~needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len > haystack_len then false
  else
    let found = ref false in
    let i = ref 0 in
    while !i <= haystack_len - needle_len && not !found do
      if String.sub haystack !i needle_len = needle then found := true;
      incr i
    done;
    !found

(** Resolve which skill effect an NPC triggers on a given turn.
    Deterministic: based on archetype category and turn number.
    - Skirmishers: "Quick Strike" on even turns (BonusDamage 1)
    - Brutes: "Crushing Blow" on turns divisible by 3 (DoubleDamage)
    - Casters: "Spell Surge" on turns divisible by 4 (MultiTarget)
    - Elites: "War Cry" on turn 1 (SelfHeal of 25% max HP) *)
let resolve_npc_skill ~turn ~npc_template =
  let arch = npc_template.archetype in
  if string_contains ~haystack:arch ~needle:"skirmisher" then
    if turn mod 2 = 0 then BonusDamage 1 else NoSkill
  else if
    string_contains ~haystack:arch ~needle:"brute"
    || string_contains ~haystack:arch ~needle:"construct"
  then if turn mod 3 = 0 then DoubleDamage else NoSkill
  else if string_contains ~haystack:arch ~needle:"caster" then
    if turn mod 4 = 0 then MultiTarget else NoSkill
  else if string_contains ~haystack:arch ~needle:"elite" then
    if turn = 1 then SelfHeal (npc_template.base_hp / 4) else NoSkill
  else NoSkill

(** Human-readable name for a skill effect. *)
let skill_effect_name = function
  | BonusDamage _ -> "Quick Strike"
  | DoubleDamage -> "Crushing Blow"
  | MultiTarget -> "Spell Surge"
  | SelfHeal _ -> "War Cry"
  | NoSkill -> ""

let append_combat_semantic_event ~base_dir ~room_id ~phase ~turn ~actor_id ~reply
    ~state =
  let ( let* ) = Result.bind in
  match detect_combat_semantic reply with
  | None -> Ok []
  | Some Combat_attack_intent ->
      let target_id = choose_attack_target_id ~state ~actor_id in
      let damage = deterministic_damage ~turn ~actor_id () in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action", `String reply);
            ( "target_id",
              match target_id with Some target -> `String target | None -> `Null );
            ("skill", `Null);
            ( "damage",
              match target_id with Some _ -> `Int damage | None -> `Null );
          ]
      in
      let* combat_event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Combat_attack ~actor_id ~payload ()
      in
      let* hp_event_opt =
        match target_id with
        | None -> Ok None
        | Some target_actor_id ->
            let hp_payload =
              `Assoc
                [
                  ("turn", `Int turn);
                  ("phase", `String phase);
                  ("actor_id", `String target_actor_id);
                  ("delta", `Int (-damage));
                  ("source_actor_id", `String actor_id);
                  ("reason", `String "combat.attack");
                ]
            in
            let* hp_event =
              append_event ~base_dir ~room_id
                ~event_type:Trpg_engine_event.Hp_changed
                ~actor_id:target_actor_id ~payload:hp_payload ()
            in
            Ok (Some hp_event)
      in
      Ok
        (match hp_event_opt with
        | Some hp_event -> [ combat_event; hp_event ]
        | None -> [ combat_event ])
  | Some Combat_defense_intent ->
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("method", `String reply);
            ("source_actor_id", `Null);
            ("mitigated", `Null);
          ]
      in
      let* event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Combat_defense ~actor_id ~payload ()
      in
      Ok [ event ]

let actor_hp_from_state state actor_id =
  match actor_json_of_state state actor_id with
  | Some actor_json ->
      actor_json |> member "hp" |> to_int_option
      |> Option.value ~default:0
  | None -> 0

let memory_floor_for_structured_action ~state ~(sa : structured_action) ~target_id
    ~damage_opt : memory_tier * string list =
  match sa.sa_type with
  | SetFlag ->
      let key =
        sa.flag_key |> Option.value ~default:"" |> String.trim
        |> String.lowercase_ascii
      in
      if starts_with key "outcome." || starts_with key "ending." then
        (Memory_long, [ "set_flag_outcome" ])
      else (Memory_mid, [ "set_flag" ])
  | SceneTransition -> (Memory_mid, [ "scene_transition" ])
  | QuestUpdate -> (Memory_mid, [ "quest_update" ])
  | Attack -> (
      match target_id, damage_opt with
      | Some target_actor_id, Some damage ->
          let hp_before = actor_hp_from_state state target_actor_id in
          if hp_before > 0 && hp_before - damage <= 0 then
            (Memory_long, [ "attack_lethal" ])
          else (Memory_short, [])
      | _ -> (Memory_short, []))
  | Defend | Heal | Investigate | Social | Explore | Magic | UseItem ->
      (Memory_short, [])

let default_importance_for_memory_tier = function
  | Memory_short -> 44
  | Memory_mid -> 62
  | Memory_long -> 82

let append_structured_action_memory_signal ~base_dir ~room_id ~turn ~phase
    ~actor_id ~(sa : structured_action) ~floor_tier ~floor_reasons =
  let ( let* ) = Result.bind in
  let requested_tier, importance_score, hint_reason =
    match sa.memory_hint with
    | Some hint ->
        ( hint.requested_tier,
          hint.importance_score
          |> Option.map (clamp_int 0 100)
          |> Option.value ~default:(default_importance_for_memory_tier hint.requested_tier),
          hint.reason )
    | None ->
        ( floor_tier,
          default_importance_for_memory_tier floor_tier,
          None )
  in
  let effective_tier = max_memory_tier requested_tier floor_tier in
  let guardrail_applied =
    memory_tier_rank effective_tier > memory_tier_rank requested_tier
  in
  if sa.memory_hint = None && effective_tier = Memory_short then Ok None
  else
    let floor_reasons = dedupe_keep_order floor_reasons in
    let summary_seed =
      let compact = String.trim sa.description in
      if compact <> "" then compact
      else
        Printf.sprintf "%s action by %s"
          (string_of_action_type sa.sa_type)
          actor_id
    in
    let summary_en =
      Printf.sprintf
        "Structured action memory decision (%s): %s"
        (string_of_action_type sa.sa_type)
        summary_seed
    in
    let summary_ko =
      Printf.sprintf
        "구조화 액션 메모리 판정 (%s): %s"
        (string_of_action_type sa.sa_type)
        summary_seed
    in
    let* event =
      append_memory_signal_event ~base_dir ~room_id
        ~event_tier:(string_of_memory_tier effective_tier)
        ~importance_score
        ~summary_ko
        ~summary_en
        ~entity_refs:
          [
            ("source", `String "structured_action");
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action_type", `String (string_of_action_type sa.sa_type));
            ("requested_tier", `String (string_of_memory_tier requested_tier));
            ("floor_tier", `String (string_of_memory_tier floor_tier));
            ("effective_tier", `String (string_of_memory_tier effective_tier));
            ("guardrail_applied", `Bool guardrail_applied);
            ( "floor_reasons",
              `List (List.map (fun reason -> `String reason) floor_reasons) );
            ( "hint_reason",
              match hint_reason with Some reason -> `String reason | None -> `Null );
          ]
    in
    Ok (Some event)

let apply_structured_action ~base_dir ~room_id ~turn ~phase ~actor_id ~state
    (sa : structured_action) =
  let ( let* ) = Result.bind in
  let finalize ~events ~target_id ~damage_opt =
    let floor_tier, floor_reasons =
      memory_floor_for_structured_action ~state ~sa ~target_id ~damage_opt
    in
    let* memory_event_opt =
      append_structured_action_memory_signal ~base_dir ~room_id ~turn ~phase
        ~actor_id ~sa ~floor_tier ~floor_reasons
    in
    Ok
      (match memory_event_opt with
      | Some memory_event -> events @ [ memory_event ]
      | None -> events)
  in
  match sa.sa_type with
  | Attack ->
      let target_id = choose_attack_target_id ~state ~actor_id in
      let damage = deterministic_damage ~turn ~actor_id () in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action", `String sa.description);
            ( "target_id",
              match target_id with Some t -> `String t | None -> `Null );
            ("skill", `Null);
            ( "damage",
              match target_id with Some _ -> `Int damage | None -> `Null );
          ]
      in
      let* combat_event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Combat_attack ~actor_id ~payload ()
      in
      let* hp_event_opt =
        match target_id with
        | None -> Ok None
        | Some target_actor_id ->
            let hp_payload =
              `Assoc
                [
                  ("turn", `Int turn);
                  ("phase", `String phase);
                  ("actor_id", `String target_actor_id);
                  ("delta", `Int (-damage));
                  ("source_actor_id", `String actor_id);
                  ("reason", `String "combat.attack");
                ]
            in
            let* hp_event =
              append_event ~base_dir ~room_id
                ~event_type:Trpg_engine_event.Hp_changed
                ~actor_id:target_actor_id ~payload:hp_payload ()
            in
            Ok (Some hp_event)
      in
      let events =
        match hp_event_opt with
        | Some hp_event -> [ combat_event; hp_event ]
        | None -> [ combat_event ]
      in
      finalize ~events ~target_id ~damage_opt:(Some damage)
  | Defend ->
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("method", `String sa.description);
            ("source_actor_id", `Null);
            ("mitigated", `Null);
          ]
      in
      let* event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Combat_defense ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | SetFlag ->
      let key = match sa.flag_key with Some k -> k | None -> "" in
      if key = "" then Ok []
      else
        let payload =
          `Assoc
            [
              ("turn", `Int turn);
              ("phase", `String phase);
              ("key", `String key);
              ("value", `String "true");
              ("description", `String sa.description);
            ]
        in
        let* event =
          append_event ~base_dir ~room_id
            ~event_type:Trpg_engine_event.Flag_set ~actor_id ~payload ()
        in
        finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | SceneTransition ->
      let scene =
        match sa.scene with Some s -> s | None -> sa.description
      in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("scene", `String scene);
            ("description", `String sa.description);
          ]
      in
      let* event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Scene_transition ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | QuestUpdate ->
      let quest_info =
        match sa.quest_info with Some q -> q | None -> sa.description
      in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("quest", `String quest_info);
            ("description", `String sa.description);
          ]
      in
      let* event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Quest_update ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:None ~damage_opt:None
  | Heal | Investigate | Social | Explore | Magic | UseItem ->
      let type_label = string_of_action_type sa.sa_type in
      let payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String actor_id);
            ("action_type", `String type_label);
            ( "target_id",
              match sa.target_id with Some t -> `String t | None -> `Null );
            ("narration", `String sa.description);
          ]
      in
      let* event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Narration_posted ~actor_id ~payload ()
      in
      finalize ~events:[ event ] ~target_id:sa.target_id ~damage_opt:None

let ensure_round_npc_spawn_event ~base_dir ~room_id ~turn ~state =
  let has_live_npc =
    party_fields_of_state state
    |> List.exists (fun (_, actor_json) ->
           is_actor_alive actor_json && role_from_actor_json actor_json = "npc")
  in
  if has_live_npc then Ok None
  else
    let existing = party_fields_of_state state in
    let rec pick_id idx =
      let candidate = Printf.sprintf "npc-t%d-%02d" turn idx in
      if List.mem_assoc candidate existing then pick_id (idx + 1) else candidate
    in
    let npc_id = pick_id 1 in
    let tmpl = select_npc_template ~turn in
    let hp = scale_hp ~turn ~base_hp:tmpl.base_hp in
    let payload =
      `Assoc
        [
          ("turn", `Int turn);
          ("phase", `String "round");
          ("actor_id", `String npc_id);
          ( "actor",
            `Assoc
              [
                ("name", `String tmpl.npc_name);
                ("role", `String "npc");
                ("archetype", `String tmpl.archetype);
                ("persona", `String tmpl.persona);
                ( "traits",
                  `List (List.map (fun t -> `String t) tmpl.traits) );
                ( "skills",
                  `List (List.map (fun s -> `String s) tmpl.skills) );
                ("hp", `Int hp);
                ("max_hp", `Int hp);
                ("alive", `Bool true);
                ("inventory", `List []);
              ] );
        ]
    in
    let ( let* ) = Result.bind in
    let* event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Actor_spawned
        ~actor_id:npc_id ~payload ()
    in
    Ok (Some event)

let default_placeholder_reply = "상황을 살피며 다음 행동을 준비합니다."

let state_turn state =
  match state |> member "turn" with
  | `Int n when n > 0 -> n
  | _ -> 1

let non_empty_string_list_field json key =
  match json |> member key with
  | `List xs ->
      xs
      |> List.filter_map (function
           | `String s when String.trim s <> "" -> Some (String.trim s)
           | `Assoc fields -> (
               match List.assoc_opt "name" fields with
               | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
               | _ -> (
                   match List.assoc_opt "id" fields with
                   | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
                   | _ -> None ) )
           | _ -> None)
  | _ -> []

let last_actor_reply ~state ~actor_id =
  match state |> member "narration_log" with
  | `List entries ->
      entries
      |> List.rev
      |> List.find_map (fun entry ->
             match entry with
             | `Assoc fields -> (
                 match List.assoc_opt "actor_id" fields with
                 | Some (`String aid) when aid = actor_id -> (
                     match List.assoc_opt "reply" fields with
                     | Some (`String reply) when String.trim reply <> "" ->
                         Some (String.trim reply)
                     | _ -> (
                         match List.assoc_opt "proposed_action" fields with
                         | Some (`String reply) when String.trim reply <> "" ->
                             Some (String.trim reply)
                         | _ -> None ) )
                 | _ -> None )
              | _ -> None)
  | _ -> None

let normalize_reply_for_comparison (raw : string) : string =
  raw
  |> String.trim
  |> String.lowercase_ascii
  |> String.split_on_char ' '
  |> List.filter (fun s -> s <> "")
  |> String.concat " "

let recent_actor_replies ~state ~actor_id ~limit =
  if limit <= 0 then []
  else
    match state |> member "narration_log" with
    | `List entries ->
        let rec collect acc = function
          | [] -> List.rev acc
          | _ when List.length acc >= limit -> List.rev acc
          | entry :: tl -> (
              match entry with
              | `Assoc fields -> (
                  match List.assoc_opt "actor_id" fields with
                  | Some (`String aid) when aid = actor_id -> (
                      match
                        List.assoc_opt "reply" fields
                        |> Option.value
                             ~default:(Option.value ~default:`Null
                                         (List.assoc_opt "proposed_action" fields))
                      with
                      | `String reply when String.trim reply <> "" ->
                          collect (String.trim reply :: acc) tl
                      | _ -> collect acc tl )
                  | _ -> collect acc tl )
              | _ -> collect acc tl)
        in
        collect [] (List.rev entries)
    | _ -> []

let pick_deterministic_text ~actor_id ~turn ~salt xs =
  match xs with
  | [] -> None
  | _ ->
      let hash = Hashtbl.hash (actor_id ^ ":" ^ string_of_int turn ^ ":" ^ salt) in
      let idx = (if hash < 0 then -hash else hash) mod List.length xs in
      Some (List.nth xs idx)

let contains_any_substring text keywords =
  List.exists (fun keyword -> contains_substring text keyword) keywords

let pick_deterministic_text_excluding_many ~actor_id ~turn ~salt ~excludes xs =
  let normalized_excludes =
    excludes
    |> List.map normalize_reply_for_comparison
    |> List.filter (fun s -> s <> "")
  in
  let rec loop attempt fallback =
    if attempt > 10 then fallback
    else
      let salt' =
        if attempt = 0 then salt else Printf.sprintf "%s:alt:%d" salt attempt
      in
      match pick_deterministic_text ~actor_id ~turn ~salt:salt' xs with
      | Some candidate ->
          let normalized_candidate = normalize_reply_for_comparison candidate in
          if List.mem normalized_candidate normalized_excludes then
            let next_fallback = if fallback = None then Some candidate else fallback in
            loop (attempt + 1) next_fallback
          else Some candidate
      | None -> fallback
  in
  loop 0 None

let pick_deterministic_text_excluding ~actor_id ~turn ~salt ~exclude xs =
  let normalized_exclude = String.trim exclude in
  let rec loop attempt fallback =
    if attempt > 4 then fallback
    else
      let salt' =
        if attempt = 0 then salt else Printf.sprintf "%s:alt:%d" salt attempt
      in
      match pick_deterministic_text ~actor_id ~turn ~salt:salt' xs with
      | Some candidate when String.trim candidate <> normalized_exclude ->
          Some candidate
      | Some candidate ->
          let next_fallback = if fallback = None then Some candidate else fallback in
          loop (attempt + 1) next_fallback
      | None -> fallback
  in
  loop 0 None

let fallback_dm_reply ~state =
  let turn = state_turn state in
  let recent_replies = recent_actor_replies ~state ~actor_id:"dm" ~limit:3 in
  let live_npcs =
    party_fields_of_state state
    |> List.fold_left
         (fun acc (_, actor_json) ->
           if is_actor_alive actor_json && role_from_actor_json actor_json = "npc" then acc + 1
           else acc)
         0
  in
  let live_pcs =
    party_fields_of_state state
    |> List.fold_left
         (fun acc (_, actor_json) ->
           if is_actor_alive actor_json && role_from_actor_json actor_json <> "npc" then acc + 1
           else acc)
         0
  in
  let templates =
    if live_npcs > 0 then
      [
        (fun t n _p ->
          Printf.sprintf "턴 %d, 남은 %d명의 적이 대열을 고쳐 잡고 다음 공격을 준비한다." t n);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 적의 지휘관이 짧은 구호를 외치자 잔존 병력이 밀집 대형으로 전환한다." t);
        (fun t n _p ->
          Printf.sprintf "턴 %d, 흙먼지 사이로 %d개의 그림자가 천천히 위치를 바꾸며 측면을 노린다." t n);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 전장에 잠시 정적이 흐르지만 적의 눈빛은 여전히 전의를 품고 있다." t);
        (fun t _n p ->
          Printf.sprintf "턴 %d, 적이 아군 %d명의 배치를 살피며 약점을 탐색하는 기색이다." t p);
        (fun t n _p ->
          Printf.sprintf "턴 %d, %d명의 적이 짧게 숨을 고른 뒤 동시에 무기를 들어올린다." t n);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 바닥에 떨어진 무기가 달그락거리고 적 진영에서 다시 움직임이 감지된다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 적의 후열에서 무언가를 준비하는 소리가 들려온다." t);
      ]
    else
      [
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 전장에 고요가 내려앉지만 어딘가에서 발소리가 가까워지고 있다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 쓰러진 적들 사이로 찬 바람이 불어오고 새로운 위협의 기척이 느껴진다." t);
        (fun t _n p ->
          Printf.sprintf "턴 %d, 일행 %d명이 잠시 숨을 돌리지만 주변의 어둠이 점점 짙어지고 있다." t p);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 멀리서 낮은 포효 소리가 울려오고 대지가 미세하게 진동한다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 전투의 잔향이 가시기도 전에 새로운 그림자가 시야 끝에 나타난다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 바닥의 핏자국이 어딘가로 이어지고 있다. 아직 끝나지 않았다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 지하에서 무언가가 움직이는 둔탁한 소리가 일행의 긴장을 다시 끌어올린다." t);
        (fun t _n _p ->
          Printf.sprintf "턴 %d, 고요한 순간도 잠시, 벽 너머에서 금속이 부딪히는 소리가 들린다." t);
      ]
  in
  let dm_actor_id = "__dm__" in
  let candidates = List.map (fun template -> template turn live_npcs live_pcs) templates in
  let selected =
    match recent_replies with
    | [] ->
        pick_deterministic_text ~actor_id:dm_actor_id ~turn ~salt:"dm-fallback" candidates
    | replies ->
        pick_deterministic_text_excluding_many ~actor_id:dm_actor_id ~turn
          ~salt:"dm-fallback" ~excludes:replies candidates
  in
  match selected with
  | Some reply -> reply
  | None -> Printf.sprintf "턴 %d, 전장의 상황이 다시 요동치기 시작한다." turn

let fallback_player_reply ~state ~actor_id =
  let turn = state_turn state in
  let recent_replies = recent_actor_replies ~state ~actor_id ~limit:3 in
  let skills, traits =
    match actor_json_of_state state actor_id with
    | Some actor_json ->
        ( non_empty_string_list_field actor_json "skills",
          non_empty_string_list_field actor_json "traits" )
    | None -> ([], [])
  in
  let trait_hint =
    pick_deterministic_text ~actor_id ~turn ~salt:"trait" traits
    |> Option.map (fun trait -> Printf.sprintf " (%s 성향)" trait)
    |> Option.value ~default:""
  in
  match pick_deterministic_text ~actor_id ~turn ~salt:"skill" skills with
  | Some skill ->
      let key = String.lowercase_ascii (String.trim skill) in
      let templates =
        if
          contains_any_substring key
            [ "mend"; "heal"; "truce"; "resolve"; "ward"; "anchor" ]
        then
          [
            Printf.sprintf
              "%s%s로 동료의 호흡을 정비해 붕괴 직전 전열을 안정시킨다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 사용해 위험한 아군을 먼저 보호하고 회복 시간을 확보한다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 일행의 흔들린 페이스를 되찾아 다음 턴의 성공 확률을 끌어올린다."
              skill trait_hint;
          ]
        else if
          contains_any_substring key
            [ "deception"; "favor"; "broker"; "shadow"; "charm" ]
        then
          [
            Printf.sprintf
              "%s%s를 활용해 상대의 판단을 흔들고 유리한 협상 구도를 만든다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 주의를 다른 곳으로 돌린 뒤 핵심 목표에 접근한다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 통해 정보 우위를 확보하고 다음 행동 선택지를 늘린다."
              skill trait_hint;
          ]
        else if
          contains_any_substring key
            [ "supply"; "ration"; "logistics"; "scan"; "omen"; "trace" ]
        then
          [
            Printf.sprintf
              "%s%s로 변수와 자원 손실을 먼저 점검해 무리한 돌입을 막는다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 사용해 위험 구간을 표시하고 안전한 진행 루트를 제시한다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 전장의 흐름을 재평가해 파티 운영 효율을 끌어올린다."
              skill trait_hint;
          ]
        else if
          contains_any_substring key [ "shield"; "intercept"; "guard"; "defense" ]
        then
          [
            Printf.sprintf
              "%s%s로 아군 전면을 받치며 적의 강공 타이밍을 흘려낸다."
              skill trait_hint;
            Printf.sprintf
              "%s%s를 통해 적의 집중 화력을 분산시키고 진형 붕괴를 막는다."
              skill trait_hint;
            Printf.sprintf
              "%s%s로 반격 각도를 만들기 전까지 버티는 시간을 번다."
              skill trait_hint;
          ]
        else
          [
            Printf.sprintf "%s%s로 적 전열의 약한 지점을 파고들어 공격한다." skill
              trait_hint;
            Printf.sprintf "%s%s를 활용해 측면을 압박하며 핵심 목표를 공격한다." skill
              trait_hint;
            Printf.sprintf "%s%s로 빈틈을 열고 전선을 밀어붙인다." skill trait_hint;
            Printf.sprintf "%s%s를 연계해 적의 대응 전에 먼저 주도권을 잡는다." skill
              trait_hint;
          ]
      in
      let selected =
        match recent_replies with
        | [] -> pick_deterministic_text ~actor_id ~turn ~salt:"skill-template" templates
        | replies ->
            pick_deterministic_text_excluding_many ~actor_id ~turn
              ~salt:"skill-template" ~excludes:replies templates
      in
      (match selected with
      | Some reply -> reply
      | None -> Printf.sprintf "%s%s로 적을 공격해 전선을 밀어붙인다." skill trait_hint)
  | None ->
      let templates =
        [
          Printf.sprintf "지형을 이용해%s 적의 허점을 노려 공격한다." trait_hint;
          Printf.sprintf "호흡을 고르고%s 적의 빈틈을 확인한 뒤 공격한다." trait_hint;
          Printf.sprintf "전열을 정비하고%s 확실한 타이밍에 공격한다." trait_hint;
          Printf.sprintf "교전을 길게 끌지 않기 위해%s 짧고 강한 일격을 노린다." trait_hint;
        ]
      in
      let selected =
        match recent_replies with
        | [] -> pick_deterministic_text ~actor_id ~turn ~salt:"plain-template" templates
        | replies ->
            pick_deterministic_text_excluding_many ~actor_id ~turn
              ~salt:"plain-template" ~excludes:replies templates
      in
      (match selected with
      | Some reply -> reply
      | None -> Printf.sprintf "적의 빈틈을 노려%s 공격한다." trait_hint)

let choose_live_npc_actor_id state =
  party_fields_of_state state
  |> List.find_map (fun (actor_id, actor_json) ->
         if is_actor_alive actor_json && role_from_actor_json actor_json = "npc" then
           Some actor_id
         else None)

(** Find a second live player target (excluding the primary target and NPC).
    Deterministic selection based on turn and actor_id hash. *)
let choose_second_player_target ~state ~npc_actor_id ~exclude_actor_id ~turn =
  let live_players =
    party_fields_of_state state
    |> List.filter (fun (aid, actor_json) ->
           aid <> npc_actor_id
           && aid <> exclude_actor_id
           && is_actor_alive actor_json
           && role_from_actor_json actor_json <> "npc"
           && role_from_actor_json actor_json <> "dm")
  in
  match live_players with
  | [] -> None
  | _ ->
      let len = List.length live_players in
      let hash = Hashtbl.hash (npc_actor_id ^ ":multi:" ^ string_of_int turn) in
      let idx = (if hash < 0 then -hash else hash) mod len in
      Some (fst (List.nth live_players idx))

let append_npc_counterattack_events ~base_dir ~room_id ~phase ~turn ~state =
  let ( let* ) = Result.bind in
  let spawn_npc_for_pressure state =
    let existing = party_fields_of_state state in
    let rec pick_id idx =
      let candidate = Printf.sprintf "npc-t%d-%02d" turn idx in
      if List.mem_assoc candidate existing then pick_id (idx + 1) else candidate
    in
    let npc_id = pick_id 1 in
    let tmpl = select_npc_template ~turn in
    let hp = scale_hp ~turn ~base_hp:tmpl.base_hp in
    let npc_actor_json =
      `Assoc
        [
          ("name", `String tmpl.npc_name);
          ("role", `String "npc");
          ("archetype", `String tmpl.archetype);
          ("persona", `String tmpl.persona);
          ("traits", `List (List.map (fun t -> `String t) tmpl.traits));
          ("skills", `List (List.map (fun s -> `String s) tmpl.skills));
          ("hp", `Int hp);
          ("max_hp", `Int hp);
          ("alive", `Bool true);
          ("inventory", `List []);
        ]
    in
    let spawn_payload =
      `Assoc
        [
          ("turn", `Int turn);
          ("phase", `String phase);
          ("actor_id", `String npc_id);
          ("actor", npc_actor_json);
        ]
    in
    let* spawn_event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Actor_spawned ~actor_id:npc_id
        ~payload:spawn_payload ()
    in
    let state_with_spawn =
      match state with
      | `Assoc fields ->
          let party_fields = party_fields_of_state state in
          let next_party =
            `Assoc ((npc_id, npc_actor_json) :: List.remove_assoc npc_id party_fields)
          in
          `Assoc (("party", next_party) :: List.remove_assoc "party" fields)
      | _ -> state
    in
    Ok (state_with_spawn, [ spawn_event ], npc_id)
  in
  let* state_for_attack, bootstrap_events, npc_actor_id =
    match choose_live_npc_actor_id state with
    | Some npc_id -> Ok (state, [], npc_id)
    | None -> spawn_npc_for_pressure state
  in
  match choose_attack_target_id ~state:state_for_attack ~actor_id:npc_actor_id with
  | None -> Ok bootstrap_events
  | Some target_actor_id ->
      (* Look up NPC name from state -> find bestiary template *)
      let npc_tmpl =
        match actor_json_of_state state_for_attack npc_actor_id with
        | Some actor_json -> (
            match actor_json |> member "name" with
            | `String name -> find_npc_template_by_name name
            | _ -> None)
        | None -> None
      in
      let damage_range =
        match npc_tmpl with
        | Some t -> (t.damage_min, t.damage_max)
        | None -> (2, 4)
      in
      let narration =
        match npc_tmpl with
        | Some t -> npc_attack_narration ~turn ~npc_template:t
        | None -> "잔존한 적이 반격해 전열을 흔든다."
      in
      let base_damage =
        deterministic_damage ~turn ~actor_id:npc_actor_id ~damage_range ()
      in
      (* Resolve archetype skill effect *)
      let skill =
        match npc_tmpl with
        | Some t -> resolve_npc_skill ~turn ~npc_template:t
        | None -> NoSkill
      in
      let skill_name_str = skill_effect_name skill in
      let skill_json =
        if skill_name_str = "" then `Null else `String skill_name_str
      in
      (* Apply skill effects *)
      let pre_attack_events = ref [] in
      let damage =
        match skill with
        | BonusDamage n -> base_damage + n
        | DoubleDamage -> base_damage * 2
        | _ -> base_damage
      in
      (* SelfHeal: emit hp.changed event with positive delta before attack *)
      (match skill with
      | SelfHeal heal_amount when heal_amount > 0 ->
          let heal_payload =
            `Assoc
              [
                ("turn", `Int turn);
                ("phase", `String phase);
                ("actor_id", `String npc_actor_id);
                ("delta", `Int heal_amount);
                ("source_actor_id", `String npc_actor_id);
                ("reason", `String "skill.war_cry");
              ]
          in
          (match
             append_event ~base_dir ~room_id
               ~event_type:Trpg_engine_event.Hp_changed
               ~actor_id:npc_actor_id ~payload:heal_payload ()
           with
          | Ok ev -> pre_attack_events := [ ev ]
          | Error _ -> ())
      | _ -> ());
      let narration_with_skill =
        if skill_name_str = "" then narration
        else Printf.sprintf "[%s] %s" skill_name_str narration
      in
      let attack_payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String npc_actor_id);
            ("action", `String narration_with_skill);
            ("target_id", `String target_actor_id);
            ("skill", skill_json);
            ("damage", `Int damage);
          ]
      in
      let* attack_event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Combat_attack ~actor_id:npc_actor_id
          ~payload:attack_payload ()
      in
      let hp_payload =
        `Assoc
          [
            ("turn", `Int turn);
            ("phase", `String phase);
            ("actor_id", `String target_actor_id);
            ("delta", `Int (-damage));
            ("source_actor_id", `String npc_actor_id);
            ("reason", `String "combat.attack");
          ]
      in
      let* hp_event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Hp_changed ~actor_id:target_actor_id
          ~payload:hp_payload ()
      in
      (* MultiTarget: attack a second player target if available *)
      let* extra_events =
        match skill with
        | MultiTarget -> (
            match
              choose_second_player_target ~state:state_for_attack ~npc_actor_id
                ~exclude_actor_id:target_actor_id ~turn
            with
            | None -> Ok []
            | Some second_target_id ->
                let second_damage =
                  deterministic_damage ~turn
                    ~actor_id:(npc_actor_id ^ "-multi") ~damage_range ()
                in
                let second_narration =
                  Printf.sprintf "[Spell Surge] 주문의 여파가 %s에게도 번진다."
                    second_target_id
                in
                let second_attack_payload =
                  `Assoc
                    [
                      ("turn", `Int turn);
                      ("phase", `String phase);
                      ("actor_id", `String npc_actor_id);
                      ("action", `String second_narration);
                      ("target_id", `String second_target_id);
                      ("skill", `String "Spell Surge");
                      ("damage", `Int second_damage);
                    ]
                in
                let* second_attack_ev =
                  append_event ~base_dir ~room_id
                    ~event_type:Trpg_engine_event.Combat_attack
                    ~actor_id:npc_actor_id ~payload:second_attack_payload ()
                in
                let second_hp_payload =
                  `Assoc
                    [
                      ("turn", `Int turn);
                      ("phase", `String phase);
                      ("actor_id", `String second_target_id);
                      ("delta", `Int (-second_damage));
                      ("source_actor_id", `String npc_actor_id);
                      ("reason", `String "combat.attack");
                    ]
                in
                let* second_hp_ev =
                  append_event ~base_dir ~room_id
                    ~event_type:Trpg_engine_event.Hp_changed
                    ~actor_id:second_target_id ~payload:second_hp_payload ()
                in
                Ok [ second_attack_ev; second_hp_ev ])
        | _ -> Ok []
      in
      Ok (bootstrap_events @ !pre_attack_events @ [ attack_event; hp_event ] @ extra_events)

let is_placeholder_reply (raw : string) : bool =
  let normalized = String.lowercase_ascii (String.trim raw) in
  normalized = String.lowercase_ascii default_placeholder_reply
  || normalized = "assess the situation and prepare the next move."

let truncate_before_marker s marker =
  match find_substring s marker with
  | Some idx -> String.sub s 0 idx
  | None -> s

let sanitize_keeper_reply (raw : string) : string =
  let text =
    raw
    |> truncate_before_marker "\"visible_state_json\":"
    |> truncate_before_marker "visible_state_json:"
    |> truncate_before_marker "\"[STATE]\""
    |> truncate_before_marker "[STATE]"
    |> truncate_before_marker "[/STATE]"
  in
  let rec strip_state_block in_state acc = function
    | [] -> List.rev acc
    | line :: tl ->
        let t = String.trim line in
        if in_state then
          if starts_with t "[/STATE]" then strip_state_block false acc tl
          else strip_state_block true acc tl
        else if starts_with t "[STATE]" then strip_state_block true acc tl
        else strip_state_block false (line :: acc) tl
  in
  let lines = strip_state_block false [] (String.split_on_char '\n' text) in
  let is_noise_line line =
    let t = String.trim line in
    let lowered = String.lowercase_ascii t in
    t = ""
    || starts_with lowered "structured_action:"
    || starts_with t "\"reply\":"
    || starts_with t "SKILL:"
    || starts_with t "SKILL_REASON:"
    || starts_with t "room_id="
    || starts_with t "phase="
    || starts_with t "turn="
    || starts_with t "role="
    || starts_with t "actor_id="
    || starts_with t "\"TRPG 실행 요청"
    || starts_with t "TRPG 실행 요청입니다."
    || starts_with t "TRPG execution request."
    || starts_with t "내 기록상 가장 처음 물어본 건 이거야"
    || contains_substring t "visible_state_json:"
  in
  let rec drop_leading_noise = function
    | [] -> []
    | line :: tl when is_noise_line line -> drop_leading_noise tl
    | xs -> xs
  in
  let cleaned_lines =
    lines
    |> List.filter (fun line ->
           let t = String.trim line in
           let lowered = String.lowercase_ascii t in
           not
             (starts_with t "```json"
             || t = "```"
             || starts_with lowered "structured_action:"
             || starts_with t "[STATE]"
             || starts_with t "[/STATE]"
             || starts_with t "visible_state_json:"))
    |> drop_leading_noise
  in
  String.concat "\n" cleaned_lines |> String.trim

let is_reply_noise_text (raw : string) : bool =
  let t = String.trim raw in
  let lowered = String.lowercase_ascii t in
  t = ""
  || starts_with t "```"
  || starts_with lowered "structured_action:"
  || starts_with t "[STATE]"
  || starts_with t "[/STATE]"
  || starts_with t "\"reply\":"
  || starts_with t "SKILL:"
  || starts_with t "SKILL_REASON:"
  || starts_with t "room_id="
  || starts_with t "phase="
  || starts_with t "turn="
  || starts_with t "role="
  || starts_with t "actor_id="
  || starts_with t "\"TRPG 실행 요청"
  || starts_with t "TRPG 실행 요청입니다."
  || starts_with t "TRPG execution request."
  || starts_with t "내 기록상 가장 처음 물어본 건 이거야"
  || starts_with t "반드시 한국어로 응답하세요."
  || contains_substring t "visible_state_json:"

let extract_skill_hint_from_text (raw : string) : string option =
  let lines =
    raw |> String.split_on_char '\n' |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  in
  let extract_skill line =
    let t = String.trim line in
    if starts_with t "SKILL:" then
      let payload =
        String.sub t (String.length "SKILL:") (String.length t - String.length "SKILL:")
        |> String.trim
      in
      if payload = "" then None else Some payload
    else None
  in
  List.find_map extract_skill lines

let fallback_reply_from_keeper_json keeper_json =
  let is_meta_skill_hint skill =
    let lowered = String.lowercase_ascii (String.trim skill) in
    (* TRPG skills are never meta-skills — they produce in-game content *)
    if starts_with lowered "trpg-" then false
    else
      starts_with lowered "masc-"
      || starts_with lowered "lodge-"
      || starts_with lowered "heartbeat"
      || contains_substring lowered "keeper"
      || contains_substring lowered "autonomy"
  in
  let skill_from_meta =
    match keeper_json |> member "skill_primary" with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  let skill_hint =
    match skill_from_meta with
    | Some skill -> Some skill
    | None -> (
        match keeper_json |> member "reply" with
        | `String s -> extract_skill_hint_from_text s
        | _ -> None )
  in
  match skill_hint with
  | Some skill when skill <> "" ->
      if is_meta_skill_hint skill then Some "상황을 살피며 다음 행동을 준비합니다."
      else Some (Printf.sprintf "%s 스킬을 활용해 행동을 이어갑니다." skill)
  | _ -> None

let parse_keeper_reply keeper_json =
  let default_fallback_reply = default_placeholder_reply in
  let raw_reply =
    match first_nonempty_string_field [ "reply"; "content"; "text"; "message" ] keeper_json with
    | Some raw -> Some raw
    | None -> (
        match keeper_json |> member "structured_action" with
        | `Assoc fields when fields <> [] ->
            Some (Yojson.Safe.to_string (`Assoc [ ("structured_action", `Assoc fields) ]))
        | _ -> None )
  in
  match raw_reply with
  | None -> (
      match fallback_reply_from_keeper_json keeper_json with
      | Some reply when String.trim reply <> "" -> Ok reply
      | _ -> Ok default_fallback_reply)
  | Some s ->
      let cleaned = sanitize_keeper_reply s in
      let fallback = String.trim s in
      let prompt_echo =
        contains_substring s "visible_state_json:"
        && (contains_substring s "TRPG 실행 요청입니다."
           || contains_substring s "TRPG execution request."
           || contains_substring s "내 기록상 가장 처음 물어본 건 이거야"
           || contains_substring s "당신은 던전 마스터"
           || contains_substring s "You are the Dungeon Master"
           || contains_substring s "캐릭터에 맞게 행동하고"
           || contains_substring s "Respond in-character as")
      in
      let fallback_reply = fallback_reply_from_keeper_json keeper_json in
      let structured_action_description =
        match extract_structured_action keeper_json with
        | Some sa when String.trim sa.description <> "" -> Some sa.description
        | _ -> None
      in
      let reply =
        if cleaned <> "" then Some cleaned
        else if structured_action_description <> None then structured_action_description
        else if prompt_echo || is_reply_noise_text fallback then fallback_reply
        else Some fallback
      in
      (match reply with
      | Some reply when String.trim reply <> "" -> Ok reply
      | _ -> (
          match fallback_reply with
          | Some reply when String.trim reply <> "" -> Ok reply
          | _ ->
              if is_reply_noise_text fallback then
                Error
                  "meta-only reply: response contained only state/noise \
                   markers"
              else Ok default_fallback_reply))

(** Attempt to recover truncated JSON by closing unclosed braces/brackets.
    Returns None if the input cannot be recovered. *)
let recover_truncated_json (raw : string) : Yojson.Safe.t option =
  let trimmed = String.trim raw in
  if String.length trimmed = 0 then None
  else
    let open_braces = ref 0 in
    let open_brackets = ref 0 in
    let in_string = ref false in
    let escaped = ref false in
    String.iter
      (fun c ->
        if !escaped then escaped := false
        else
          match c with
          | '\\' when !in_string -> escaped := true
          | '"' -> in_string := not !in_string
          | '{' when not !in_string -> incr open_braces
          | '}' when not !in_string -> decr open_braces
          | '[' when not !in_string -> incr open_brackets
          | ']' when not !in_string -> decr open_brackets
          | _ -> ())
      trimmed;
    if !in_string then begin
      (* Close unclosed string *)
      let buf = Buffer.create (String.length trimmed + 16) in
      Buffer.add_string buf trimmed;
      Buffer.add_char buf '"';
      for _ = 1 to !open_brackets do
        Buffer.add_char buf ']'
      done;
      for _ = 1 to !open_braces do
        Buffer.add_char buf '}'
      done;
      (try Some (Yojson.Safe.from_string (Buffer.contents buf))
       with Yojson.Json_error _ -> None)
    end
    else if !open_braces > 0 || !open_brackets > 0 then begin
      let buf = Buffer.create (String.length trimmed + 16) in
      Buffer.add_string buf trimmed;
      for _ = 1 to !open_brackets do
        Buffer.add_char buf ']'
      done;
      for _ = 1 to !open_braces do
        Buffer.add_char buf '}'
      done;
      (try Some (Yojson.Safe.from_string (Buffer.contents buf))
       with Yojson.Json_error _ -> None)
    end
    else None

(** Parse a raw string as keeper JSON, with truncated JSON recovery.
    Tries normal Yojson parse first. On failure, attempts to close unclosed
    braces/brackets and re-parse. Returns the parsed reply or an error. *)
let parse_keeper_reply_raw (raw : string) =
  let try_parse s =
    try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None
  in
  match try_parse raw with
  | Some json -> parse_keeper_reply json
  | None -> (
      match recover_truncated_json raw with
      | Some json ->
          Printf.eprintf
            "[WARN] parse_keeper_reply_raw: recovered truncated JSON\n%!";
          parse_keeper_reply json
      | None ->
          (* Not JSON at all — treat the raw text as the reply *)
          let trimmed = String.trim raw in
          if trimmed <> "" then Ok trimmed
          else Error "empty raw keeper response")

type prompt_language = [ `Ko | `En ]

let prompt_language_of_string_opt = function
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "ko" | "kr" | "korean" -> `Ko
      | "en" | "english" -> `En
      | _ -> `Ko)
  | None -> `Ko

let take_last n xs =
  if n <= 0 then []
  else
    let len = List.length xs in
    let drop = max 0 (len - n) in
    let rec skip k ys =
      if k <= 0 then ys
      else
        match ys with
        | [] -> []
        | _ :: tl -> skip (k - 1) tl
    in
    skip drop xs

let compact_text ?(max_len = 320) s =
  let chunks =
    s |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  in
  let flat = String.concat " " chunks in
  if String.length flat <= max_len then flat
  else String.sub flat 0 max_len ^ "..."

let compact_narration_entry (entry : Yojson.Safe.t) : Yojson.Safe.t =
  match entry with
  | `Assoc fields ->
      let keep_key key =
        match List.assoc_opt key fields with Some v -> Some (key, v) | None -> None
      in
      let core =
        [ "phase"; "turn"; "role"; "actor_id"; "keeper" ]
        |> List.filter_map keep_key
      in
      let reply =
        match List.assoc_opt "reply" fields with
        | Some (`String s) when String.trim s <> "" ->
            [ ("reply", `String (compact_text ~max_len:360 s)) ]
        | _ -> []
      in
      `Assoc (core @ reply)
  | _ -> entry

let compact_state_for_prompt (state : Yojson.Safe.t) : Yojson.Safe.t =
  match state with
  | `Assoc fields ->
      let get key = List.assoc_opt key fields in
      let pick keys =
        keys |> List.filter_map (fun key ->
            match get key with Some v -> Some (key, v) | None -> None)
      in
      let narration_log =
        match get "narration_log" with
        | Some (`List xs) ->
            `List (xs |> take_last 8 |> List.map compact_narration_entry)
        | _ -> `List []
      in
      let dice_log =
        match get "dice_log" with
        | Some (`List xs) -> `List (take_last 8 xs)
        | _ -> `List []
      in
      `Assoc
        (pick
           [
             "turn";
             "phase";
             "status";
             "current_node";
             "world";
             "config";
             "party";
             "actor_control";
             "interventions";
           ]
        @ [ ("narration_log", narration_log); ("dice_log", dice_log) ])
  | _ -> state

type dm_persona_id =
  | Dm_grim_gothic
  | Dm_tactical_irony
  | Dm_heroic_epic

let dm_persona_id_of_string = function
  | "grim_gothic" | "grim-gothic" | "grim" -> Some Dm_grim_gothic
  | "tactical_irony" | "tactical-irony" | "tactical" -> Some Dm_tactical_irony
  | "heroic_epic" | "heroic-epic" | "heroic" -> Some Dm_heroic_epic
  | _ -> None

let string_of_dm_persona_id = function
  | Dm_grim_gothic -> "grim_gothic"
  | Dm_tactical_irony -> "tactical_irony"
  | Dm_heroic_epic -> "heroic_epic"

let infer_dm_persona_id ~explicit ~dm_style =
  match explicit with
  | Some id -> id
  | None ->
      let lowered = String.lowercase_ascii (String.trim dm_style) in
      if
        contains_substring lowered "grim"
        || contains_substring lowered "gothic"
        || contains_substring lowered "horror"
      then Dm_grim_gothic
      else if
        contains_substring lowered "tactic"
        || contains_substring lowered "irony"
        || contains_substring lowered "wry"
      then Dm_tactical_irony
      else Dm_heroic_epic

let dm_persona_directive_ko = function
  | Dm_grim_gothic ->
      "페르소나: Grim Gothic. 분위기는 음울하고 냉혹하게, 대가와 상흔을 분명히 제시하세요."
  | Dm_tactical_irony ->
      "페르소나: Tactical Irony. 전술적 긴장과 건조한 아이러니를 유지하고 선택의 비용을 숫자처럼 명확히 보여주세요."
  | Dm_heroic_epic ->
      "페르소나: Heroic Epic. 영웅 서사의 고조를 유지하되 승리도 희생과 위험을 통과해야 얻어지게 만드세요."

let dm_persona_directive_en = function
  | Dm_grim_gothic ->
      "Persona: Grim Gothic. Keep the tone bleak and costly; make scars and consequences explicit."
  | Dm_tactical_irony ->
      "Persona: Tactical Irony. Keep tactical pressure with dry irony; make costs and trade-offs explicit."
  | Dm_heroic_epic ->
      "Persona: Heroic Epic. Build heroic momentum, but every win must pass through risk and sacrifice."

type prompt_context = {
  actor_name : string;
  actor_persona : string;
  actor_archetype : string;
  actor_traits : string list;
  actor_skills : string list;
  actor_inventory : string list;
  actor_equipment : (string * string) list;
  scene_description : string;
  scene_mood : string;
  narrative_recent : string list;
  party_summary : string;
  relationships : (string * string) list;
  world_weather : string;
  world_time : string;
  dm_style : string;
  dm_opening_prompt : string;
  dm_persona_id : dm_persona_id;
  dm_persona_override : bool;
  (* Phase 1-3: Keeper Intelligence Harness fields *)
  bdi_fragment : string;
  dm_intent_hint : string;
  narrative_arc_phase : string;
  character_memory_notes : string;
}

let empty_prompt_context =
  {
    actor_name = "";
    actor_persona = "";
    actor_archetype = "";
    actor_traits = [];
    actor_skills = [];
    actor_inventory = [];
    actor_equipment = [];
    scene_description = "";
    scene_mood = "";
    narrative_recent = [];
    party_summary = "";
    relationships = [];
    world_weather = "";
    world_time = "";
    dm_style = "";
    dm_opening_prompt = "";
    dm_persona_id = Dm_heroic_epic;
    dm_persona_override = false;
    bdi_fragment = "";
    dm_intent_hint = "";
    narrative_arc_phase = "";
    character_memory_notes = "";
  }

let get_string_field json key =
  match json with
  | `Null -> ""
  | _ -> ( match json |> member key with `String s -> s | _ -> "")

let get_string_list_field json key =
  match json with
  | `Null -> []
  | _ -> (
      match json |> member key with
      | `List xs ->
          xs
          |> List.filter_map (function
               | `String s when String.trim s <> "" -> Some s
               | _ -> None)
      | _ -> [])

let extract_narrative_recent (state : Yojson.Safe.t) : string list =
  match state |> member "narration_log" with
  | `List xs ->
      xs |> take_last 5
      |> List.filter_map (fun entry ->
             match entry |> member "reply" with
             | `String s when String.trim s <> "" ->
                 let actor =
                   match entry |> member "actor_id" with
                   | `String a -> a
                   | _ -> "?"
                 in
                 Some (Printf.sprintf "[%s] %s" actor (compact_text ~max_len:200 s))
             | _ -> None)
  | _ -> []

let extract_party_summary ~exclude_actor_id (state : Yojson.Safe.t) : string =
  match state |> member "party" with
  | `Assoc members ->
      members
      |> List.filter_map (fun (aid, actor_json) ->
             if aid = exclude_actor_id then None
             else
               let name = get_string_field actor_json "name" in
               let arch = get_string_field actor_json "archetype" in
               let alive =
                 match actor_json |> member "alive" with
                 | `Bool b -> b
                 | _ -> true
               in
               if name = "" then None
               else
                 let status = if alive then "" else " [dead]" in
                 Some (Printf.sprintf "%s (%s)%s" name arch status))
      |> String.concat ", "
  | _ -> ""

let extract_equipment_fields (actor_json : Yojson.Safe.t) :
    (string * string) list =
  match actor_json with
  | `Null -> []
  | _ -> (
      match actor_json |> member "equipment" with
      | `Assoc pairs ->
          pairs
          |> List.filter_map (fun (slot, v) ->
                 match v with
                 | `String name when String.trim name <> "" ->
                     Some (slot, String.trim name)
                 | _ -> None)
      | `List items ->
          items
          |> List.filter_map (fun item ->
                 let slot = get_string_field item "slot" in
                 let name = get_string_field item "name" in
                 if slot <> "" && name <> "" then Some (slot, name) else None)
      | _ -> [])

(** Jaccard similarity between two word sets: |A inter B| / |A union B|. *)
let jaccard_similarity a b =
  let module SSet = Set.Make (String) in
  let set_a = SSet.of_list a in
  let set_b = SSet.of_list b in
  let inter = SSet.cardinal (SSet.inter set_a set_b) in
  let union = SSet.cardinal (SSet.union set_a set_b) in
  if union = 0 then 0.0 else Float.of_int inter /. Float.of_int union

let tokenize_words s =
  s |> String.lowercase_ascii |> String.split_on_char ' '
  |> List.concat_map (String.split_on_char '\n')
  |> List.filter (fun w -> String.length w > 0)

(** Check if a new narration entry is too similar to recent entries.
    Returns true if the entry should be skipped (>60% Jaccard overlap with
    any of the last 3 entries). *)
let is_narration_duplicate ~recent_replies (new_reply : string) : bool =
  let new_tokens = tokenize_words new_reply in
  recent_replies
  |> List.exists (fun prev ->
         let prev_tokens = tokenize_words prev in
         jaccard_similarity new_tokens prev_tokens > 0.6)

(** Extract last N reply strings from narration_log. *)
let extract_recent_replies ?(n = 3) (state : Yojson.Safe.t) : string list =
  match state |> member "narration_log" with
  | `List xs ->
      xs |> take_last n
      |> List.filter_map (fun entry ->
             match entry |> member "reply" with
             | `String s when String.trim s <> "" -> Some (String.trim s)
             | _ -> None)
  | _ -> []

(** Deduplicate a narration log list. For each entry, check if its reply
    is >60% Jaccard-similar to any of the preceding 3 entries. If so, skip. *)
let deduplicate_narration (entries : Yojson.Safe.t list) :
    Yojson.Safe.t list =
  let _recent, kept =
    List.fold_left
      (fun (recent, acc) entry ->
        let reply =
          match entry |> member "reply" with
          | `String s -> String.trim s
          | _ -> ""
        in
        if reply = "" then (recent, entry :: acc)
        else if is_narration_duplicate ~recent_replies:recent reply then
          (recent, acc)
        else
          let recent' = (reply :: recent) |> take_last 3 in
          (recent', entry :: acc))
      ([], []) entries
  in
  List.rev kept

(** Classify the relationship between actor_id and another actor based on
    keyword occurrence in narration log entries where both appear.
    Returns (other_actor_name, relation_type) pairs. *)
let extract_relationships ~actor_id (state : Yojson.Safe.t) :
    (string * string) list =
  let ally_keywords =
    [ "heal"; "help"; "protect"; "치유"; "도움"; "보호"; "회복" ]
  in
  let rival_keywords =
    [ "attack"; "hit"; "slash"; "strike"; "공격"; "타격"; "베" ]
  in
  let party_members =
    match state |> member "party" with
    | `Assoc members ->
        members
        |> List.filter_map (fun (aid, aj) ->
               if aid = actor_id then None
               else
                 let name = get_string_field aj "name" in
                 if name = "" then None else Some (aid, name))
    | _ -> []
  in
  let actor_name =
    match state |> member "party" with
    | `Assoc members -> (
        match List.assoc_opt actor_id members with
        | Some actor_json -> get_string_field actor_json "name"
        | None -> "")
    | _ -> ""
  in
  let actor_name_l = String.lowercase_ascii actor_name in
  let entries =
    match state |> member "narration_log" with
    | `List xs -> xs
    | _ -> []
  in
  party_members
  |> List.filter_map (fun (other_id, other_name) ->
         let ally_score = ref 0 in
         let rival_score = ref 0 in
         let co_count = ref 0 in
         entries
         |> List.iter (fun entry ->
                let reply =
                  match entry |> member "reply" with
                  | `String s -> String.lowercase_ascii s
                  | _ -> ""
                in
                let entry_actor =
                  match entry |> member "actor_id" with
                  | `String a -> a
                  | _ -> ""
                in
                let other_name_l = String.lowercase_ascii other_name in
                let involves_both =
                  (entry_actor = actor_id
                  && find_substring reply other_name_l <> None)
                  || (entry_actor = other_id && find_substring reply actor_name_l <> None)
                in
                if involves_both then begin
                  incr co_count;
                  if
                    List.exists
                      (fun kw -> find_substring reply kw <> None)
                      ally_keywords
                  then incr ally_score;
                  if
                    List.exists
                      (fun kw -> find_substring reply kw <> None)
                      rival_keywords
                  then incr rival_score
                end);
         if !co_count = 0 then None
         else
           let relation =
             if !ally_score > !rival_score then "ally"
             else if !rival_score > !ally_score then "rival"
             else "neutral"
           in
           Some (other_name, relation))

let extract_prompt_context ~actor_id ?(dm_persona_override = None)
    (state : Yojson.Safe.t) : prompt_context =
  let actor_json =
    match state |> member "party" with
    | `Assoc members -> (
        match List.assoc_opt actor_id members with
        | Some j -> j
        | None -> `Null)
    | _ -> `Null
  in
  let world_json = state |> member "world" in
  let dm_json =
    match state |> member "config" with
    | `Assoc fields -> (
        match List.assoc_opt "dm" fields with
        | Some value -> value
        | None -> `Null)
    | _ -> `Null
  in
  let dm_style = get_string_field dm_json "style" in
  let inferred_dm_persona =
    infer_dm_persona_id
      ~explicit:
        (Option.bind dm_persona_override (fun raw ->
             dm_persona_id_of_string
               (String.lowercase_ascii (String.trim raw))))
      ~dm_style
  in
  {
    actor_name = get_string_field actor_json "name";
    actor_persona = get_string_field actor_json "persona";
    actor_archetype = get_string_field actor_json "archetype";
    actor_traits = get_string_list_field actor_json "traits";
    actor_skills = get_string_list_field actor_json "skills";
    actor_inventory = get_string_list_field actor_json "inventory";
    actor_equipment = extract_equipment_fields actor_json;
    scene_description = get_string_field world_json "description";
    scene_mood = get_string_field world_json "intro";
    narrative_recent = extract_narrative_recent state;
    party_summary = extract_party_summary ~exclude_actor_id:actor_id state;
    relationships = extract_relationships ~actor_id state;
    world_weather =
      (let flags = get_string_list_field world_json "story_flags" in
       flags
       |> List.filter (fun f ->
              String.length f > 8
              && String.sub f 0 8 = "weather.")
       |> (function x :: _ -> x | [] -> ""));
    world_time =
      (let flags = get_string_list_field world_json "story_flags" in
       flags
       |> List.filter (fun f ->
              String.length f > 5
              && String.sub f 0 5 = "time.")
       |> (function x :: _ -> x | [] -> ""));
    dm_style;
    dm_opening_prompt = get_string_field dm_json "opening_prompt";
    dm_persona_id = inferred_dm_persona;
    dm_persona_override = Option.is_some dm_persona_override;
    bdi_fragment = "";
    dm_intent_hint = "";
    narrative_arc_phase = "";
    character_memory_notes = "";
  }

let join_nonempty sep items =
  items |> List.filter (fun s -> String.trim s <> "") |> String.concat sep

let format_traits traits =
  match traits with [] -> "" | ts -> String.concat ", " ts

let trpg_structured_action_system_instructions =
  "CRITICAL: Your response MUST contain a JSON object called structured_action.\n\
   Place it on its own line in your reply, exactly like this:\n\n\
   structured_action: {\"type\":\"<ACTION_TYPE>\",\"description\":\"<what you do>\"}\n\n\
   Optional memory hint (engine may up-tier via guardrail floor):\n\
   \"memory_hint\":{\"tier\":\"short|mid|long\",\"importance_score\":0-100,\"reason\":\"why this memory matters\"}\n\n\
   Available ACTION_TYPE values:\n\
   - Player actions: attack, defend, heal, investigate, social, explore, magic, use_item\n\
   - DM actions: set_flag, scene_transition, quest_update\n\n\
   Examples:\n\
   structured_action: {\"type\":\"attack\",\"target_id\":\"goblin-1\",\"description\":\"Swing sword at the goblin\"}\n\
   structured_action: {\"type\":\"set_flag\",\"flag_key\":\"quest.hideout.found\",\"description\":\"The party discovered the hideout\"}\n\
   structured_action: {\"type\":\"scene_transition\",\"scene\":\"Deep cave\",\"description\":\"The party enters the cave\",\"memory_hint\":{\"tier\":\"mid\",\"reason\":\"scene pivot\"}}\n\
   structured_action: {\"type\":\"scene_transition\",\"scene\":\"Deep cave\",\"description\":\"The party enters the cave\"}\n\n\
   Rules:\n\
   1. EVERY response must have exactly one structured_action line.\n\
   2. The JSON must be valid (use double quotes for keys and string values).\n\
   3. Do NOT wrap it in markdown code blocks.\n\
   4. Place it at the END of your narrative reply."

let build_player_section_ko (ctx : prompt_context) =
  let parts =
    [
      Printf.sprintf "당신은 '%s'입니다." ctx.actor_name;
      "당신은 보조자나 해설자가 아니라, 이 캐릭터의 의사결정을 직접 수행하는 플레이어입니다.";
      "메타 설명(시스템/프롬프트/모델/정책 언급)은 금지됩니다. 캐릭터의 관점으로만 응답하세요.";
      (if ctx.actor_archetype <> "" then
         Printf.sprintf "직업/역할: %s." ctx.actor_archetype
       else "");
      (if ctx.actor_persona <> "" then
         Printf.sprintf "성격: %s" ctx.actor_persona
       else "");
      (if ctx.actor_traits <> [] then
         Printf.sprintf "특성: %s." (format_traits ctx.actor_traits)
       else "");
      (if ctx.actor_skills <> [] then
         Printf.sprintf "보유 기술: %s." (format_traits ctx.actor_skills)
       else "");
      (match ctx.actor_equipment with
      | [] -> ""
      | eq ->
          Printf.sprintf "장착 중: %s."
            (eq
            |> List.map (fun (slot, name) ->
                   Printf.sprintf "%s(%s)" name slot)
            |> String.concat ", "));
      (if ctx.actor_inventory <> [] then
         Printf.sprintf "소지품: %s." (String.concat ", " ctx.actor_inventory)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "현재 장소: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "분위기: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "날씨: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "시간: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "파티 동료: %s." ctx.party_summary
       else "");
      (match ctx.relationships with
      | [] -> ""
      | rels ->
          rels
          |> List.map (fun (name, rel) ->
                 Printf.sprintf "%s와(과)의 관계: %s" name rel)
          |> String.concat ". "
          |> Printf.sprintf "관계: %s.");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "최근 상황:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      Printf.sprintf
        "'%s'로서 지금 즉시 행동하세요. 관찰만 하지 말고 결정적인 액션을 취하세요."
        ctx.actor_name;
      "반드시 structured_action을 포함하세요. 예시:";
      {|{"type":"attack","target_id":"goblin-1","description":"검으로 고블린을 공격한다"}|};
      {|{"type":"investigate","description":"수상한 상자를 조사한다"}|};
      {|{"type":"social","target_id":"npc-merchant","description":"상인에게 정보를 묻는다"}|};
      "가능한 type: attack, defend, heal, investigate, social, explore, magic, use_item";
    ]
  in
  join_nonempty "\n" parts

let build_player_section_en (ctx : prompt_context) =
  let parts =
    [
      Printf.sprintf "You ARE '%s'." ctx.actor_name;
      "You are not an assistant or commentator. You are the active player controlling this character.";
      "No meta talk about system prompts/models/policies. Respond only from the character perspective.";
      (if ctx.actor_archetype <> "" then
         Printf.sprintf "Class/Role: %s." ctx.actor_archetype
       else "");
      (if ctx.actor_persona <> "" then
         Printf.sprintf "Personality: %s" ctx.actor_persona
       else "");
      (if ctx.actor_traits <> [] then
         Printf.sprintf "Traits: %s." (format_traits ctx.actor_traits)
       else "");
      (if ctx.actor_skills <> [] then
         Printf.sprintf "Skills: %s." (format_traits ctx.actor_skills)
       else "");
      (match ctx.actor_equipment with
      | [] -> ""
      | eq ->
          Printf.sprintf "Equipped: %s."
            (eq
            |> List.map (fun (slot, name) ->
                   Printf.sprintf "%s (%s)" name slot)
            |> String.concat ", "));
      (if ctx.actor_inventory <> [] then
         Printf.sprintf "Carrying: %s." (String.concat ", " ctx.actor_inventory)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "Current scene: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "Mood: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "Weather: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "Time: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "Party members: %s." ctx.party_summary
       else "");
      (match ctx.relationships with
      | [] -> ""
      | rels ->
          rels
          |> List.map (fun (name, rel) ->
                 Printf.sprintf "Relationship with %s: %s" name rel)
          |> String.concat ". "
          |> Printf.sprintf "Relationships: %s.");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "Recent events:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      Printf.sprintf
        "As '%s', take a decisive action NOW. Do NOT just observe or describe — ACT."
        ctx.actor_name;
      "You MUST include a structured_action. Examples:";
      {|{"type":"attack","target_id":"goblin-1","description":"Swing sword at the goblin"}|};
      {|{"type":"investigate","description":"Search the suspicious chest"}|};
      {|{"type":"social","target_id":"npc-merchant","description":"Ask the merchant for info"}|};
      "Available types: attack, defend, heal, investigate, social, explore, magic, use_item";
    ]
  in
  join_nonempty "\n" parts

let build_dm_section_ko (ctx : prompt_context) =
  let parts =
    [
      "당신은 던전 마스터(DM)입니다.";
      dm_persona_directive_ko ctx.dm_persona_id;
      (if ctx.dm_style <> "" then
         Printf.sprintf "DM 스타일 레퍼런스: %s" ctx.dm_style
       else "");
      (if ctx.dm_opening_prompt <> "" then
         Printf.sprintf "세션 테마: %s" (compact_text ~max_len:180 ctx.dm_opening_prompt)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "현재 장면: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "분위기: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "날씨: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "시간: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "파티 구성: %s." ctx.party_summary
       else "");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "최근 서사:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      "다음에 일어날 일을 결정하세요. 서사를 진행하고, 환경과 NPC의 반응을 묘사하세요.";
      "반드시 structured_action을 포함하세요. DM용 예시:";
      {|{"type":"set_flag","flag_key":"quest.hideout.found","description":"일행이 은신처를 발견했다"}|};
      {|{"type":"scene_transition","scene":"동굴 깊은 곳","description":"일행이 동굴 안으로 진입한다"}|};
      {|{"type":"quest_update","quest_info":"보스 위치 확인됨","description":"단서를 통해 보스 위치가 드러났다"}|};
      "DM은 set_flag, scene_transition, quest_update만 사용하세요.";
      "스토리 목표 달성 시 [WIN], 전멸 시 [LOSE]를 reply에 포함하세요.";
      "매 턴마다 이야기를 진전시키세요. 같은 상황을 반복하지 마세요.";
    ]
  in
  join_nonempty "\n" parts

let build_dm_section_en (ctx : prompt_context) =
  let parts =
    [
      "You are the Dungeon Master (DM).";
      dm_persona_directive_en ctx.dm_persona_id;
      (if ctx.dm_style <> "" then
         Printf.sprintf "DM style reference: %s" ctx.dm_style
       else "");
      (if ctx.dm_opening_prompt <> "" then
         Printf.sprintf "Session theme: %s" (compact_text ~max_len:180 ctx.dm_opening_prompt)
       else "");
      (if ctx.scene_description <> "" then
         Printf.sprintf "Current scene: %s" ctx.scene_description
       else "");
      (if ctx.scene_mood <> "" then
         Printf.sprintf "Mood: %s" ctx.scene_mood
       else "");
      (if ctx.world_weather <> "" then
         Printf.sprintf "Weather: %s." ctx.world_weather
       else "");
      (if ctx.world_time <> "" then
         Printf.sprintf "Time: %s." ctx.world_time
       else "");
      (if ctx.party_summary <> "" then
         Printf.sprintf "Party composition: %s." ctx.party_summary
       else "");
      (match ctx.narrative_recent with
      | [] -> ""
      | lines ->
          Printf.sprintf "Recent narrative:\n%s"
            (lines |> List.map (fun l -> "- " ^ l) |> String.concat "\n"));
      "Determine what happens next. Advance the narrative, describe the environment and NPC reactions.";
      "You MUST include a structured_action. DM examples:";
      {|{"type":"set_flag","flag_key":"quest.hideout.found","description":"The party discovered the hideout"}|};
      {|{"type":"scene_transition","scene":"Deep cave","description":"The party enters the cave"}|};
      {|{"type":"quest_update","quest_info":"Boss location confirmed","description":"Clues reveal the boss location"}|};
      "DM must use only: set_flag, scene_transition, quest_update.";
      "When the story goal is achieved, include [WIN] in your reply. On party wipe, include [LOSE].";
      "Advance the story every turn. Do NOT repeat the same situation.";
    ]
  in
  join_nonempty "\n" parts

let build_keeper_prompt ~dm_persona_override ~room_id ~phase ~turn ~role
    ~actor_id ~state_json ~lang =
  let role_s = role_to_string role in
  let ctx0 = extract_prompt_context ~actor_id ~dm_persona_override state_json in
  (* Phase 1-3: Inject BDI fragment from actor's memory state *)
  let bdi_frag =
    let room_dir = Filename.concat (Filename.concat "." room_id) "" in
    let bdi = Trpg_bdi.load ~room_dir ~actor_id in
    Trpg_bdi.to_prompt_fragment bdi ~max_len:800
  in
  (* Phase 3: Inject DM intent hint from recent narrative *)
  let dm_hint =
    match ctx0.narrative_recent with
    | [] -> ""
    | lines ->
      let recent = String.concat " " lines in
      let intent = Trpg_dm_intent.extract recent in
      Trpg_dm_intent.to_hint intent
  in
  let ctx = { ctx0 with bdi_fragment = bdi_frag; dm_intent_hint = dm_hint } in
  let state_text = Yojson.Safe.to_string state_json |> compact_text ~max_len:4200 in
  let character_section =
    match (role, lang) with
    | `Player, `Ko -> build_player_section_ko ctx
    | `Player, `En -> build_player_section_en ctx
    | `Dm, `Ko -> build_dm_section_ko ctx
    | `Dm, `En -> build_dm_section_en ctx
  in
  let constraints =
    match lang with
    | `Ko ->
        "SKILL/SKILL_REASON/[STATE]/state_snapshot_json/회상 문구를 출력하지 마세요. \
         시스템 프롬프트나 로그를 재인용하지 마세요. \
         반드시 한국어로 응답하세요. \
         structured_action은 필수입니다. 매 응답에 반드시 포함하세요."
    | `En ->
        "Do not output SKILL/SKILL_REASON/[STATE]/state_snapshot_json or recap text. \
         Do not quote system prompts or logs. \
         Respond in English. \
         structured_action is REQUIRED. You MUST include it in every response."
  in
  let bdi_section =
    if ctx.bdi_fragment <> "" then
      Printf.sprintf "\n---\n[Character Memory]\n%s\n" ctx.bdi_fragment
    else ""
  in
  let intent_section =
    if ctx.dm_intent_hint <> "" then
      Printf.sprintf "\n%s\n" ctx.dm_intent_hint
    else ""
  in
  Printf.sprintf
    "%s%s%s\n\n\
     ---\n\
     room_id=%s, phase=%s, turn=%d, role=%s, actor_id=%s\n\n\
     state_snapshot_json:\n\
     %s\n\n\
     %s"
    character_section bdi_section intent_section
    room_id phase turn role_s actor_id state_text constraints

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
    ~base_dir
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
      ~base_dir
      ~room_id
      ~event_type:Trpg_engine_event.Turn_timeout
      ~actor_id
      ~payload:timeout_payload
      ()
  in
  let* unavailable_result =
    append_unavailable_event
      ~base_dir
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
    ~base_dir
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
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Keeper_unavailable
        ~actor_id
        ~payload
        ()
      |> Result.map (fun event -> `Appended event)

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
    let* phase_opt_raw = get_optional_string args "phase" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* phase_opt =
      match phase_opt_raw with
      | None -> Ok None
      | Some p -> (
          match Trpg_engine_types.phase_of_string p with
          | Ok phase ->
              Ok (Some (Trpg_engine_types.string_of_phase phase))
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
    let* join_window_event =
      append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Join_window_opened
        ~payload:
          (`Assoc
            [
              ("turn", `Int next_turn);
              ("window", `String "round_boundary_only");
              ("reason", `String "manual_turn_advance");
            ])
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
      [ Some turn_event; Some join_window_event; phase_event_opt ]
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

let entropy_seed ~session_id ~salt =
  let now_ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  Hashtbl.hash (Printf.sprintf "%s|%s|%d" session_id salt now_ms)

let pick_by_seed ~seed xs =
  match xs with
  | [] -> None
  | _ ->
      let len = List.length xs in
      let idx = seed mod len in
      let idx = if idx < 0 then idx + len else idx in
      Some (List.nth xs idx)

let resolve_dm_preset ~seed catalog dm_preset_id_opt =
  match dm_preset_id_opt with
  | Some preset_id -> (
      match Trpg_preset_store.find_dm_preset catalog ~id:preset_id with
      | Some preset -> Ok preset
      | None -> Error (Printf.sprintf "unknown dm_preset_id: %s" preset_id))
  | None -> (
      match pick_by_seed ~seed catalog.Trpg_preset_store.dm_presets with
      | Some preset -> Ok preset
      | None -> Error "no dm presets available")

let resolve_world_preset ~seed catalog world_preset_id_opt =
  match world_preset_id_opt with
  | Some preset_id -> (
      match Trpg_preset_store.find_world_preset catalog ~id:preset_id with
      | Some preset -> Ok preset
      | None -> Error (Printf.sprintf "unknown world_preset_id: %s" preset_id))
  | None -> (
      match pick_by_seed ~seed catalog.Trpg_preset_store.world_presets with
      | Some preset -> Ok preset
      | None -> Error "no world presets available")

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

let default_party_from_catalog ~seed catalog party_size =
  let capped = max 1 (min party_size 8) in
  match generate_pool_members ~catalog ~pool_size:capped ~seed with
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
  try
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
  with exn ->
    err (Printf.sprintf "preset.list failed: %s" (Printexc.to_string exn))

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
    let seed =
      Option.value ~default:(entropy_seed ~session_id ~salt:"pool.generate") seed_opt
    in
    let* catalog = Trpg_preset_store.load_catalog ~base_dir:ctx.config.base_path in
    let* dm_preset = resolve_dm_preset ~seed catalog dm_preset_id in
    (* +17 offset decorrelates world preset selection from DM selection using the same base seed *)
    let* world_preset = resolve_world_preset ~seed:(seed + 17) catalog world_preset_id in
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
    let* world_contract_id_opt = get_optional_string args "world_contract_id" in
    let* canon_strict = get_optional_bool args "canon_strict" ~default:false in
    let* dm_keeper_opt = get_optional_string args "dm_keeper" in
    let dm_keeper = dm_keeper_opt |> Option.value ~default:"dm-keeper" in
    let* phase_opt = get_optional_string args "phase" in
    let phase_input = phase_opt |> Option.value ~default:"briefing" in
    let* phase =
      match Trpg_engine_types.phase_of_string phase_input with
      | Ok phase -> Ok (Trpg_engine_types.string_of_phase phase)
      | Error e -> Error e
    in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* force = get_optional_bool args "force" ~default:false in
    let* () = validate_rule_module rule_module in
    let fallback_seed =
      entropy_seed ~session_id
        ~salt:(Printf.sprintf "session.start|%s|%s" room_id phase)
    in
    let* catalog = Trpg_preset_store.load_catalog ~base_dir in
    let* dm_preset = resolve_dm_preset ~seed:fallback_seed catalog dm_preset_id in
    let* world_preset =
      (* +19 offset decorrelates world preset selection from DM selection *)
      resolve_world_preset ~seed:(fallback_seed + 19) catalog world_preset_id
    in
    let* world_contract =
      resolve_world_contract_for_session ~base_dir
        ~world_preset_id:world_preset.id ~world_contract_id_opt
    in
    let* party =
      match args |> member "party" with
      | `List xs when xs <> [] -> pool_members_of_json_list xs
      | _ ->
          (* +37 offset decorrelates party selection from DM (+0) and world (+19) picks *)
          let fallback_party = default_party_from_catalog ~seed:(fallback_seed + 37) catalog 4 in
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
      let world_canon_ref =
        world_contract_ref_to_yojson ~contract:world_contract
          ~strict:canon_strict
      in
      let world_with_canon_config =
        match world_config ~preset:world_preset with
        | `Assoc fields ->
            `Assoc
              (("canon_contract", world_canon_ref)
              :: List.remove_assoc "canon_contract" fields)
        | world_json -> world_json
      in
      `Assoc
        [
          ("session_id", `String session_id);
          ("rule_module", `String rule_module);
          ("scenario_id", `String world_preset.id);
          ("dm_preset_id", `String dm_preset.id);
          ("world_preset_id", `String world_preset.id);
          ("world_contract_id", `String world_contract.id);
          ( "config",
            `Assoc
              [
                ("party", party_config party);
                ("world", world_with_canon_config);
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
          ("world_contract_id", `String world_contract.id);
          ("canon_strict", `Bool canon_strict);
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
    let dm_persona_default =
      infer_dm_persona_id ~explicit:None ~dm_style:dm_preset.style
      |> string_of_dm_persona_id
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
          ( "world_contract",
            world_contract_ref_to_yojson ~contract:world_contract
              ~strict:canon_strict );
          ("party", `List (List.map pool_member_to_yojson party));
          ( "round_run_template",
            `Assoc
              [
                ("room_id", `String room_id);
                ("dm_keeper", `String dm_keeper);
                ("player_keepers", player_keepers_json);
                ("phase", `String "round");
                ("dm_persona", `String dm_persona_default);
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
  add_opt_string "role" role_opt;
  add_opt_string "name" name_opt;
  add_opt_string "archetype" archetype_opt;
  add_opt_string "persona" persona_opt;
  add_opt_int "hp" hp_opt;
  add_opt_int "max_hp" max_hp_opt;
  add_opt_bool "alive" alive_opt;
  add_opt_strings "traits" traits_opt;
  add_opt_strings "skills" skills_opt;
  add_opt_strings "inventory" inventory_opt;
  if !fields = [] then
    Error
      "at least one update field is required: role,name,archetype,persona,hp,max_hp,alive,traits,skills,inventory"
  else Ok (`Assoc (List.rev !fields))

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

let handle_actor_update ctx args : result =
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
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Actor_updated
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

let handle_actor_delete ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* reason_opt = get_optional_string args "reason" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
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
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Actor_deleted
          ~actor_id ~payload ()
      in
      let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
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
    let* events = Trpg_engine_store_sqlite.read_events ~base_dir ~room_id in
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

let handle_join_eligibility ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name_opt = get_optional_string args "keeper_name" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    let state = state_of_derived derived in
    let* events = Trpg_engine_store_sqlite.read_events ~base_dir ~room_id in
    let gate = join_gate_of_state state in
    let actor_exists = actor_exists_in_state state actor_id in
    let actor_role =
      if actor_exists then actor_role_in_state state actor_id else "player"
    in
    let server_score, reasons =
      contribution_for_actor_from_events events actor_id
    in
    let keeper_eval =
      match keeper_name_opt with
      | Some keeper_name ->
          evaluate_keeper_bonus ctx ~keeper_name ~room_id ~actor_id ~server_score
            ~required_points:gate.min_points
      | None ->
          {
            bonus = 0;
            source = "server_only";
            reason = None;
            warning = None;
          }
    in
    let effective_score = server_score + keeper_eval.bonus in
    let eligible, reason_code, reason =
      if actor_role <> "player" then
        (true, None, None)
      else if not gate.phase_open then
        ( false,
          Some "join_window_closed",
          Some "mid-join is only allowed at round boundary window" )
      else if effective_score < gate.min_points then
        ( false,
          Some "insufficient_contribution",
          Some
            (Printf.sprintf "score=%d required=%d"
               effective_score gate.min_points) )
      else (true, None, None)
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("actor_id", `String actor_id);
          ("actor_exists", `Bool actor_exists);
          ("actor_role", `String actor_role);
          ("phase_open", `Bool gate.phase_open);
          ("window", `String gate.window);
          ("required_points", `Int gate.min_points);
          ("server_score", `Int server_score);
          ("keeper_bonus", `Int keeper_eval.bonus);
          ("effective_score", `Int effective_score);
          ("eligible", `Bool eligible);
          ("reason_code", Option.fold ~none:`Null ~some:(fun v -> `String v) reason_code);
          ("reason", Option.fold ~none:`Null ~some:(fun v -> `String v) reason);
          ("score_reasons", json_of_strings reasons);
          ("judge_source", `String keeper_eval.source);
          ("judge_reason", Option.fold ~none:`Null ~some:(fun v -> `String v) keeper_eval.reason);
          ("judge_warning", Option.fold ~none:`Null ~some:(fun v -> `String v) keeper_eval.warning);
          ("state", state);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_mid_join_request ctx args : result =
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
    let* events = Trpg_engine_store_sqlite.read_events ~base_dir ~room_id in
    let gate = join_gate_of_state state in
    let actor_exists = actor_exists_in_state state actor_id in
    let actor_role =
      if actor_exists then actor_role_in_state state actor_id
      else
        (match get_optional_string args "role" with
        | Ok (Some role) -> String.lowercase_ascii role
        | _ -> "player")
    in
    let server_score, score_reasons =
      contribution_for_actor_from_events events actor_id
    in
    let keeper_eval =
      evaluate_keeper_bonus ctx ~keeper_name ~room_id ~actor_id ~server_score
        ~required_points:gate.min_points
    in
    let effective_score = server_score + keeper_eval.bonus in
    let requested_payload =
      `Assoc
        [
          ("actor_id", `String actor_id);
          ("keeper_name", `String keeper_name);
          ("actor_role", `String actor_role);
          ("phase_open", `Bool gate.phase_open);
          ("window", `String gate.window);
          ("required_points", `Int gate.min_points);
          ("server_score", `Int server_score);
          ("keeper_bonus", `Int keeper_eval.bonus);
          ("effective_score", `Int effective_score);
          ("requested_by", `String ctx.agent_name);
        ]
    in
    let* requested_event =
      append_event ~base_dir ~room_id
        ~event_type:Trpg_engine_event.Mid_join_requested ~actor_id
        ~payload:requested_payload ()
    in
    let reject ~reason_code ~reason ~importance_score =
      let rejected_payload =
        `Assoc
          [
            ("actor_id", `String actor_id);
            ("keeper_name", `String keeper_name);
            ("reason_code", `String reason_code);
            ("reason", `String reason);
            ("required_points", `Int gate.min_points);
            ("effective_score", `Int effective_score);
          ]
      in
      let* rejected_event =
        append_event ~base_dir ~room_id
          ~event_type:Trpg_engine_event.Mid_join_rejected ~actor_id
          ~payload:rejected_payload ()
      in
      let* memory_event =
        append_memory_signal_event ~base_dir ~room_id ~event_tier:"short"
          ~importance_score
          ~summary_ko:(Printf.sprintf "중간 참여 거절: %s (%s)" actor_id reason_code)
          ~summary_en:(Printf.sprintf "Mid-join rejected: %s (%s)" actor_id reason_code)
          ~entity_refs:
            [
              ("actor_id", `String actor_id);
              ("keeper_name", `String keeper_name);
              ("reason_code", `String reason_code);
            ]
      in
      let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("keeper_name", `String keeper_name);
            ("granted", `Bool false);
            ("reason_code", `String reason_code);
            ("reason", `String reason);
            ("required_points", `Int gate.min_points);
            ("server_score", `Int server_score);
            ("keeper_bonus", `Int keeper_eval.bonus);
            ("effective_score", `Int effective_score);
            ("score_reasons", json_of_strings score_reasons);
            ("judge_source", `String keeper_eval.source);
            ("judge_warning", Option.fold ~none:`Null ~some:(fun v -> `String v) keeper_eval.warning);
            ( "events",
              `List
                [
                  Trpg_engine_event.to_yojson requested_event;
                  Trpg_engine_event.to_yojson rejected_event;
                  Trpg_engine_event.to_yojson memory_event;
                ] );
            ("state", state_of_derived next_derived);
          ])
    in
    if actor_exists && not (actor_alive_in_state state actor_id) then
      reject ~reason_code:"actor_not_alive"
        ~reason:"target actor is not alive"
        ~importance_score:55
    else if actor_role = "player" && not gate.phase_open then
      reject ~reason_code:"join_window_closed"
        ~reason:"mid-join is only allowed at round boundary window"
        ~importance_score:40
    else if actor_role = "player" && effective_score < gate.min_points then
      reject ~reason_code:"insufficient_contribution"
        ~reason:
          (Printf.sprintf "effective_score=%d required_points=%d"
             effective_score gate.min_points)
        ~importance_score:45
    else
      let* spawn_event_opt, state_after_spawn =
        if actor_exists then Ok (None, state)
        else
          let* actor_json = actor_payload_from_spawn_args args ~actor_id in
          let spawn_payload =
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("actor", actor_json);
                ("spawned_by", `String ctx.agent_name);
                ("source", `String "mid_join");
              ]
          in
          let* spawn_event =
            append_event ~base_dir ~room_id
              ~event_type:Trpg_engine_event.Actor_spawned ~actor_id
              ~payload:spawn_payload ()
          in
          let* d = derive_state ~base_dir ~room_id ~rule_module in
          Ok (Some spawn_event, state_of_derived d)
      in
      let normalized_keeper = normalize_keeper_name keeper_name in
      let* claim_resolution =
        match owner_for_actor state_after_spawn actor_id with
        | Some owner when normalize_keeper_name owner = normalized_keeper ->
            Ok (`Proceed (true, None, state_after_spawn))
        | Some owner -> (
            let* rejected_json =
              reject ~reason_code:"actor_claimed_by_other_keeper"
                ~reason:(Printf.sprintf "actor already claimed by %s" owner)
                ~importance_score:50
            in
            Ok (`Rejected rejected_json))
        | None -> (
            match actor_for_keeper state_after_spawn keeper_name with
            | Some current_actor -> (
                let* rejected_json =
                  reject ~reason_code:"keeper_already_controls_actor"
                    ~reason:
                      (Printf.sprintf "keeper=%s already controls actor=%s"
                         keeper_name current_actor)
                    ~importance_score:48
                in
                Ok (`Rejected rejected_json))
            | None ->
                let claim_payload =
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("keeper_name", `String keeper_name);
                      ("claimed_by", `String ctx.agent_name);
                      ("source", `String "mid_join");
                    ]
                in
                let* claim_event =
                  append_event ~base_dir ~room_id
                    ~event_type:Trpg_engine_event.Actor_claimed ~actor_id
                    ~payload:claim_payload ()
                in
                let* d = derive_state ~base_dir ~room_id ~rule_module in
                Ok (`Proceed (false, Some claim_event, state_of_derived d)))
      in
      match claim_resolution with
      | `Rejected json -> Ok json
      | `Proceed (already_claimed, claim_event_opt, state_after_claim) ->
          let* penalty_event_opt, _state_after_penalty =
            if actor_role <> "player" then Ok (None, state_after_claim)
            else
              let actor_json =
                state_after_claim |> member "party" |> member actor_id
              in
              let max_hp =
                actor_json |> member "max_hp" |> to_int_option
                |> Option.value ~default:10
              in
              let hp =
                actor_json |> member "hp" |> to_int_option
                |> Option.value ~default:max_hp
              in
              let penalty_hp_target =
                max 1 (int_of_float (float_of_int max_hp *. 0.7))
              in
              let penalty_hp = min hp penalty_hp_target in
              let actor_patch =
                `Assoc
                  [
                    ("hp", `Int penalty_hp);
                    ("late_join_penalty", `Bool true);
                    ("late_join_penalty_turns", `Int 2);
                  ]
              in
              let payload =
                `Assoc
                  [
                    ("actor_id", `String actor_id);
                    ("actor_patch", actor_patch);
                    ("updated_by", `String ctx.agent_name);
                    ("source", `String "mid_join_penalty");
                  ]
              in
              let* penalty_event =
                append_event ~base_dir ~room_id
                  ~event_type:Trpg_engine_event.Actor_updated ~actor_id
                  ~payload ()
              in
              let* d = derive_state ~base_dir ~room_id ~rule_module in
              Ok (Some penalty_event, state_of_derived d)
          in
          let granted_payload =
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("keeper_name", `String keeper_name);
                ("actor_role", `String actor_role);
                ("already_claimed", `Bool already_claimed);
                ("required_points", `Int gate.min_points);
                ("effective_score", `Int effective_score);
                ("source", `String "hard_gate");
              ]
          in
          let* granted_event =
            append_event ~base_dir ~room_id
              ~event_type:Trpg_engine_event.Mid_join_granted ~actor_id
              ~payload:granted_payload ()
          in
          let* memory_event =
            append_memory_signal_event ~base_dir ~room_id ~event_tier:"mid"
              ~importance_score:72
              ~summary_ko:
                (Printf.sprintf "중간 참여 승인: %s (%s)" actor_id keeper_name)
              ~summary_en:
                (Printf.sprintf "Mid-join granted: %s (%s)" actor_id keeper_name)
              ~entity_refs:
                [
                  ("actor_id", `String actor_id);
                  ("keeper_name", `String keeper_name);
                  ("effective_score", `Int effective_score);
                ]
          in
          let* final_derived = derive_state ~base_dir ~room_id ~rule_module in
          let events =
            [
              Some requested_event;
              spawn_event_opt;
              claim_event_opt;
              penalty_event_opt;
              Some granted_event;
              Some memory_event;
            ]
            |> List.filter_map (fun x -> x)
            |> List.map Trpg_engine_event.to_yojson
          in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("room_id", `String room_id);
                ("actor_id", `String actor_id);
                ("keeper_name", `String keeper_name);
                ("granted", `Bool true);
                ( "status",
                  `String
                    (if already_claimed then "already_claimed" else "joined")
                );
                ("required_points", `Int gate.min_points);
                ("server_score", `Int server_score);
                ("keeper_bonus", `Int keeper_eval.bonus);
                ("effective_score", `Int effective_score);
                ("score_reasons", json_of_strings score_reasons);
                ("judge_source", `String keeper_eval.source);
                ( "judge_warning",
                  Option.fold ~none:`Null
                    ~some:(fun v -> `String v)
                    keeper_eval.warning );
                ("events", `List events);
                ("state", state_of_derived final_derived);
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

let take_first_n n xs =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: tl -> loop (remaining - 1) (x :: acc) tl
  in
  loop n [] xs

let compact_summary_text ?(max_len = 96) raw =
  let compact =
    raw |> String.trim |> String.split_on_char '\n'
    |> List.map String.trim |> List.filter (fun s -> s <> "")
    |> String.concat " "
  in
  if compact = "" then ""
  else if String.length compact <= max_len then compact
  else String.sub compact 0 (max_len - 1) ^ "…"

let json_member_nonempty_string json key =
  match json |> member key with
  | `String raw ->
      let value = String.trim raw in
      if value = "" then None else Some value
  | _ -> None

let json_member_int_value json key =
  match json |> member key with
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | `Float value -> Some (int_of_float value)
  | _ -> None

let json_member_bool_value json key =
  match json |> member key with `Bool value -> Some value | _ -> None

let first_some a b = match a with Some _ -> a | None -> b
let option_filter f = function Some value when f value -> Some value | _ -> None

let status_first_non_ok_detail (statuses : Yojson.Safe.t list) : string option =
  let rec loop = function
    | [] -> None
    | status_json :: tl ->
        let status_name =
          status_json |> member "status" |> to_string_option
          |> Option.value ~default:""
          |> String.trim |> String.lowercase_ascii
        in
        if status_name = "" || status_name = "ok" then loop tl
        else
          let actor_id =
            status_json |> member "actor_id" |> to_string_option
            |> Option.value ~default:"-" |> String.trim
          in
          let stage =
            status_json |> member "stage" |> to_string_option
            |> Option.value ~default:"" |> String.trim
          in
          let reason =
            json_member_nonempty_string status_json "reason"
            |> first_some (json_member_nonempty_string status_json "error")
            |> first_some (json_member_nonempty_string status_json "reply")
            |> Option.map (compact_summary_text ~max_len:120)
          in
          let head = Printf.sprintf "%s=%s" actor_id status_name in
          let with_stage =
            if stage = "" then head else Printf.sprintf "%s @%s" head stage
          in
          Some
            (match reason with
            | Some detail when detail <> "" ->
                Printf.sprintf "%s (%s)" with_stage detail
            | _ -> with_stage)
  in
  loop statuses

let count_event_type_in_list event_type (events : Trpg_engine_event.t list) =
  List.fold_left
    (fun acc (event : Trpg_engine_event.t) ->
      if event.event_type = event_type then acc + 1 else acc)
    0 events

let count_npc_attacks_in_list (events : Trpg_engine_event.t list) =
  List.fold_left
    (fun acc (event : Trpg_engine_event.t) ->
      if event.event_type <> Trpg_engine_event.Combat_attack then acc
      else
        let actor_id =
          json_member_nonempty_string event.payload "actor_id"
          |> first_some
               (event.actor_id
               |> Option.map String.trim
               |> option_filter (fun value -> value <> ""))
          |> Option.value ~default:""
          |> String.lowercase_ascii
        in
        if String.starts_with ~prefix:"npc-" actor_id then acc + 1 else acc)
    0 events

let structured_memory_decision_of_event (event : Trpg_engine_event.t) :
    Yojson.Safe.t option =
  if event.event_type <> Trpg_engine_event.Memory_signal then None
  else
    match event.payload |> member "entity_refs" with
    | `Assoc _ as refs -> (
        match refs |> member "source" with
        | `String "structured_action" ->
            Some
              (`Assoc
                [
                  ( "requested_tier",
                    match refs |> member "requested_tier" with
                    | `String tier -> `String tier
                    | _ -> `Null );
                  ( "effective_tier",
                    match refs |> member "effective_tier" with
                    | `String tier -> `String tier
                    | _ -> `Null );
                  ( "floor_tier",
                    match refs |> member "floor_tier" with
                    | `String tier -> `String tier
                    | _ -> `Null );
                  ( "guardrail_applied",
                    match refs |> member "guardrail_applied" with
                    | `Bool b -> `Bool b
                    | _ -> `Bool false );
                ])
        | _ -> None)
    | _ -> None

let memory_status_fields_of_action_events (events : Trpg_engine_event.t list) :
    (string * Yojson.Safe.t) list =
  let decision =
    events |> List.find_map structured_memory_decision_of_event
  in
  match decision with
  | None ->
      [
        ("memory_requested_tier", `Null);
        ("memory_effective_tier", `Null);
        ("memory_floor_tier", `Null);
        ("memory_guardrail_applied", `Bool false);
      ]
  | Some memory_json ->
      [
        ("memory_requested_tier", memory_json |> member "requested_tier");
        ("memory_effective_tier", memory_json |> member "effective_tier");
        ("memory_floor_tier", memory_json |> member "floor_tier");
        ("memory_guardrail_applied", memory_json |> member "guardrail_applied");
      ]

let memory_observability_from_events (events : Trpg_engine_event.t list) :
    int * int =
  List.fold_left
    (fun (total, escalated) (event : Trpg_engine_event.t) ->
      if event.event_type <> Trpg_engine_event.Memory_signal then
        (total, escalated)
      else
        let escalated' =
          match event.payload |> member "entity_refs" |> member "guardrail_applied" with
          | `Bool true -> escalated + 1
          | _ -> escalated
        in
        (total + 1, escalated'))
    (0, 0) events

let build_round_roll_audit (events : Trpg_engine_event.t list) : Yojson.Safe.t list =
  let to_json_opt_string = function Some value -> `String value | None -> `Null in
  let to_json_opt_int = function Some value -> `Int value | None -> `Null in
  let to_json_opt_bool = function Some value -> `Bool value | None -> `Null in
  let rec collect acc = function
    | [] -> List.rev acc
    | (event : Trpg_engine_event.t) :: tl -> (
        match event.event_type with
        | Trpg_engine_event.Dice_rolled ->
            let payload = event.payload in
            let actor_id =
              json_member_nonempty_string payload "actor_id"
              |> first_some event.actor_id
            in
            let row =
              `Assoc
                [
                  ("seq", `Int event.seq);
                  ("source", `String "dice.rolled");
                  ("actor_id", to_json_opt_string actor_id);
                  ("action", to_json_opt_string (json_member_nonempty_string payload "action"));
                  ("raw_d20", to_json_opt_int (json_member_int_value payload "raw_d20"));
                  ("bonus", to_json_opt_int (json_member_int_value payload "bonus"));
                  ("total", to_json_opt_int (json_member_int_value payload "total"));
                  ("dc", to_json_opt_int (json_member_int_value payload "dc"));
                  ("passed", to_json_opt_bool (json_member_bool_value payload "passed"));
                ]
            in
            collect (row :: acc) tl
        | Trpg_engine_event.Combat_attack ->
            let payload = event.payload in
            let actor_id =
              json_member_nonempty_string payload "actor_id"
              |> first_some event.actor_id
            in
            let row =
              `Assoc
                [
                  ("seq", `Int event.seq);
                  ("source", `String "combat.attack");
                  ("resolved_by", `String "deterministic_damage");
                  ("actor_id", to_json_opt_string actor_id);
                  ( "target_id",
                    to_json_opt_string
                      (json_member_nonempty_string payload "target_id") );
                  ("damage", to_json_opt_int (json_member_int_value payload "damage"));
                  ("skill", to_json_opt_string (json_member_nonempty_string payload "skill"));
                  ( "action",
                    to_json_opt_string
                      (json_member_nonempty_string payload "action"
                      |> Option.map (compact_summary_text ~max_len:72)) );
                  ("hp_source_reason", `String "combat.attack");
                ]
            in
            collect (row :: acc) tl
        | _ -> collect acc tl)
  in
  collect [] events

let handle_round_run ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* dm_keeper_raw = get_required_string args "dm_keeper" in
    let dm_keeper = String.trim dm_keeper_raw in
    let* player_keepers = parse_player_keepers args in
    let* timeout_sec = get_optional_float args "timeout_sec" ~default:90.0 in
    if timeout_sec <= 0.0 then Error "timeout_sec must be > 0"
    else if dm_keeper = "" then Error "dm_keeper cannot be empty"
    else
      let* rule_opt = get_optional_string args "rule_module" in
      let* phase_opt = get_optional_string args "phase" in
      let* lang_opt = get_optional_string args "lang" in
      let* dm_persona_opt = get_optional_string args "dm_persona" in
      let* require_claim = get_optional_bool args "require_claim" ~default:false in
      let* local_fallback_requested =
        get_optional_bool args "local_fallback" ~default:false
      in
      let local_fallback = local_fallback_requested in
      let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
      let phase_input = Option.value ~default:"round" phase_opt in
      let prompt_lang = prompt_language_of_string_opt lang_opt in
      let* dm_persona_override =
        match dm_persona_opt with
        | None -> Ok None
        | Some raw -> (
            let normalized = String.lowercase_ascii (String.trim raw) in
            match dm_persona_id_of_string normalized with
            | Some persona -> Ok (Some (string_of_dm_persona_id persona))
            | None ->
                Error
                  "dm_persona must be one of: grim_gothic, tactical_irony, heroic_epic")
      in
      let* () =
        match ctx.keeper_call with
        | Some _ -> Ok ()
        | None -> Error "keeper_call is not available in this runtime"
      in
      let* () = validate_rule_module rule_module in
      let* phase =
        match Trpg_engine_types.phase_of_string phase_input with
        | Ok phase -> Ok (Trpg_engine_types.string_of_phase phase)
        | Error e -> Error e
      in
      let* () = validate_unique_keeper_assignments ~dm_keeper ~player_keepers in
      let assigned_keepers = dm_keeper :: List.map snd player_keepers in
      let preflight_warning =
        match keeper_preflight ctx ~keepers:assigned_keepers with
        | Ok () -> None
        | Error e ->
            Some
              (Printf.sprintf
                 "non-blocking preflight warning (snapshot): %s"
                 e)
      in
      with_keeper_reservation
        ~keepers:assigned_keepers
        (fun () ->
      let* derived = derive_state ~base_dir ~room_id ~rule_module in
      let* existing_events_before =
        Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
      in
      let session_events_before =
        events_since_last_session_marker existing_events_before
      in
      let state = state_of_derived derived in
      let room_already_ended =
        has_event_type session_events_before Trpg_engine_event.Room_ended
      in
      let outcome_already_emitted =
        has_event_type session_events_before Trpg_engine_event.Session_outcome
      in
      let end_rules =
        resolve_end_rules_for_room ~base_dir ~events:existing_events_before
      in
      let latest_outcome_payload =
        ref (latest_session_outcome_payload session_events_before)
      in
      let* turn_before = read_state_turn derived in
      let unavailable_sampling =
        make_unavailable_sampling_state ~events:existing_events_before
          ~turn:turn_before
      in
      let next_turn = max 1 (turn_before + 1) in
      let* () =
        if player_keepers = [] then
          Error "player_keepers must include at least one player actor assignment"
        else Ok ()
      in
      let* () =
        let invalid_actor =
          List.find_opt
            (fun (actor_id, _) ->
              actor_id = "dm" || not (actor_exists_in_state state actor_id))
            player_keepers
        in
        match invalid_actor with
        | Some (actor_id, _) ->
            Error
              (Printf.sprintf
                 "invalid player assignment: actor_id=%s is not a playable party actor"
                 actor_id)
        | None -> Ok ()
      in
      let live_player_keepers, dead_player_keepers =
        List.partition
          (fun (actor_id, _) -> actor_alive_in_state state actor_id)
          player_keepers
      in
      let terminal_session = room_already_ended || outcome_already_emitted in
      if terminal_session then
        let active_player_count = List.length live_player_keepers in
        let participant_count = max 1 (1 + active_player_count) in
        let keeper_timeout_sec =
          resolve_keeper_timeout_sec ~timeout_sec ~participant_count
        in
        let player_required_successes =
          let total = active_player_count in
          if total <= 0 then 0 else max 1 ((total + 1) / 2)
        in
        let terminal_reason =
          if room_already_ended && outcome_already_emitted then
            "room already ended and session outcome already emitted"
          else if room_already_ended then
            "room already ended"
          else "session outcome already emitted"
        in
        let dead_statuses =
          dead_player_keepers
          |> List.map (fun (actor_id, keeper_name) ->
                 `Assoc
                   [
                     ("actor_id", `String actor_id);
                     ("role", `String "player");
                     ("keeper", `String keeper_name);
                     ("status", `String "skipped_dead");
                     ("reason", `String "actor is not alive at round start");
                     ("stage", `String "preflight");
                   ])
        in
        let live_statuses =
          live_player_keepers
          |> List.map (fun (actor_id, keeper_name) ->
                 `Assoc
                   [
                     ("actor_id", `String actor_id);
                     ("role", `String "player");
                     ("keeper", `String keeper_name);
                     ("status", `String "skipped_session_ended");
                     ("reason", `String terminal_reason);
                     ("stage", `String "session_guard");
                   ])
        in
        let dm_status =
          `Assoc
            [
              ("actor_id", `String "dm");
              ("role", `String "dm");
              ("keeper", `String dm_keeper);
              ("status", `String "skipped_session_ended");
              ("reason", `String terminal_reason);
              ("stage", `String "session_guard");
            ]
        in
        let statuses = dead_statuses @ live_statuses @ [ dm_status ] in
        let canon_check =
          evaluate_canon_check ~base_dir ~state ~events:existing_events_before
            ~dm_reply:None
        in
        let dm_style =
          match state |> member "config" with
          | `Assoc fields -> (
              match List.assoc_opt "dm" fields with
              | Some dm_json -> get_string_field dm_json "style"
              | None -> "")
          | _ -> ""
        in
        let dm_persona_used =
          infer_dm_persona_id
            ~explicit:(Option.bind dm_persona_override dm_persona_id_of_string)
            ~dm_style
        in
        let room_status =
          match state |> member "status" with
          | `String status when String.trim status <> "" -> status
          | _ -> "ended"
        in
        Ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ("phase", `String phase);
              ("turn_before", `Int turn_before);
              ("turn_after", `Int turn_before);
              ("timeout_sec", `Float timeout_sec);
              ( "preflight_warning",
                match preflight_warning with
                | Some warning -> `String warning
                | None -> `Null );
              ("statuses", `List statuses);
              ("interventions_applied", `List []);
              ( "summary",
                `Assoc
                  [
                    ("participants", `Int participant_count);
                    ("successes", `Int 0);
                    ("fallbacks", `Int 0);
                    ("player_successes", `Int 0);
                    ("player_fallbacks", `Int 0);
                    ("player_required_successes", `Int player_required_successes);
                    ("player_quorum_met", `Bool false);
                    ("dm_success", `Bool false);
                    ("advanced", `Bool false);
                    ("progress_reason", `String "session_ended");
                    ("progress_detail", `String terminal_reason);
                    ("recovery_applied", `Bool false);
                    ( "recovery_mode",
                      if local_fallback then
                        `String "local_fallback_enabled"
                      else `String "none" );
                    ("effective_timeout_sec", `Float timeout_sec);
                    ("requested_timeout_sec", `Float timeout_sec);
                    ("keeper_timeout_sec", `Float keeper_timeout_sec);
                    ("timeouts", `Int 0);
                    ("unavailable", `Int 0);
                    ("schema_failures", `Int 0);
                    ("rule_validation_failures", `Int 0);
                    ("reprompts", `Int 0);
                    ("dm_persona", `String (string_of_dm_persona_id dm_persona_used));
                    ("dm_persona_overridden", `Bool (Option.is_some dm_persona_override));
                    ("npc_spawned", `Int 0);
                    ("npc_attacks", `Int 0);
                    ("interventions", `Int 0);
                    ("canon_status", `String canon_check.status);
                    ("canon_violation_count", `Int (List.length canon_check.violations));
                    ("canon_warning_count", `Int (List.length canon_check.warnings));
                    ("memory_signals", `Int 0);
                    ("memory_guardrail_escalations", `Int 0);
                    ("roll_audit_count", `Int 0);
                    ("roll_audit", `List []);
                  ] );
              ("canon_check", canon_check_to_yojson canon_check);
              ( "outcome",
                match !latest_outcome_payload with
                | Some payload -> payload
                | None -> `Null );
              ("events", `List []);
              ("room_status", `String room_status);
              ("state", state);
            ])
      else
      let* join_window_closed_event =
        append_event
          ~base_dir
          ~room_id
          ~event_type:Trpg_engine_event.Join_window_closed
          ~payload:
            (`Assoc
              [
                ("turn", `Int turn_before);
                ("window", `String "round_boundary_only");
                ("reason", `String "round_run_started");
              ])
          ()
      in

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
      let base_state_for_prompt =
        inject_interventions_into_state state interventions_applied
        |> compact_state_for_prompt
      in

      let appended_events =
        ref (join_window_closed_event :: phase_event :: intervention_events)
      in
      let statuses = ref [] in
      let success_count = ref 0 in
      let fallback_count = ref 0 in
      let schema_failures = ref 0 in
      let rule_validation_failures = ref 0 in
      let reprompt_count = ref 0 in
      let player_success_count = ref 0 in
      let player_fallback_count = ref 0 in
      let dm_success = ref false in
      let unavailable_count = ref 0 in
      let timeout_count = ref 0 in
      let dm_reply_ref : string option ref = ref None in
      let state_for_players_ref = ref base_state_for_prompt in
      let active_player_count = List.length live_player_keepers in
      let participant_count = max 1 (1 + active_player_count) in
      let keeper_timeout_sec =
        resolve_keeper_timeout_sec ~timeout_sec ~participant_count
      in
      let* () =
        if phase = "round" then
          let* spawn_event_opt =
            ensure_round_npc_spawn_event ~base_dir ~room_id ~turn:turn_before
              ~state:base_state_for_prompt
          in
          (match spawn_event_opt with
          | Some spawn_event ->
              appended_events := !appended_events @ [ spawn_event ];
              (match derive_state ~base_dir ~room_id ~rule_module with
              | Ok derived_after_spawn ->
                  state_for_players_ref :=
                    inject_interventions_into_state
                      (state_of_derived derived_after_spawn)
                      interventions_applied
                    |> compact_state_for_prompt
              | Error _ -> ())
          | None -> ());
          Ok ()
        else Ok ()
      in

      List.iter
        (fun (actor_id, keeper_name) ->
          statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String "player");
                ("keeper", `String keeper_name);
                ("status", `String "skipped_dead");
                ("reason", `String "actor is not alive at round start");
                ("stage", `String "preflight");
              ]
            :: !statuses)
        dead_player_keepers;

      let process_one ~state_json ~role ~actor_id ~keeper_name =
        let record_unavailable_status ~status ~error ~stage =
          let* unavailable_result =
            append_unavailable_event
              ~base_dir
              ~room_id
              ~phase
              ~turn:turn_before
              ~role
              ~actor_id
              ~keeper_name
              ~reason:error
              ~stage
              ~sampling_state:unavailable_sampling
              ()
          in
          let sampled, sampled_reason =
            match unavailable_result with
            | `Appended unavailable_event ->
                unavailable_count := !unavailable_count + 1;
                appended_events := !appended_events @ [ unavailable_event ];
                (false, None)
            | `Sampled reason -> (true, Some reason)
          in
          statuses :=
            `Assoc
              [
                ("actor_id", `String actor_id);
                ("role", `String (role_to_string role));
                ("keeper", `String keeper_name);
                ("status", `String status);
                ("reason", `String error);
                ("stage", `String stage);
                ("error", `String error);
                ("sampled", `Bool sampled);
                ( "sampled_reason",
                  Option.fold ~none:`Null ~some:(fun v -> `String v)
                    sampled_reason );
              ]
            :: !statuses;
          Ok ()
        in
        let apply_local_fallback ~stage ~reason =
          if not local_fallback then
            Error
              (Printf.sprintf
                 "local fallback disabled: actor=%s keeper=%s stage=%s reason=%s"
                 actor_id keeper_name stage reason)
          else
            let fallback_reply =
              match role with
              | `Player -> fallback_player_reply ~state:state_json ~actor_id
              | `Dm -> fallback_dm_reply ~state:state_json
            in
            let* spawn_event_opt =
              match role with
              | `Player -> Ok None
              | `Dm ->
                  ensure_round_npc_spawn_event ~base_dir ~room_id ~turn:turn_before
                    ~state:state_json
            in
            (match spawn_event_opt with
            | Some spawn_event ->
                appended_events := !appended_events @ [ spawn_event ]
            | None -> ());
            let state_for_pressure =
              match role with
              | `Player -> state_json
              | `Dm -> (
                  match spawn_event_opt with
                  | Some _ -> (
                      match derive_state ~base_dir ~room_id ~rule_module with
                      | Ok derived_after_spawn -> state_of_derived derived_after_spawn
                      | Error _ -> state_json )
                  | None -> state_json )
            in
            let* reply_event =
              append_keeper_reply_event ~base_dir ~room_id ~phase ~turn:turn_before
                ~role ~actor_id ~keeper_name ~reply:fallback_reply
            in
            fallback_count := !fallback_count + 1;
            (* NOTE: fallback does NOT increment success_count.
               Fallbacks are placeholder responses — counting them as success
               masks stagnation and prevents the game from detecting
               that no meaningful action occurred. *)
            (match role with
            | `Dm ->
                dm_success := true;
                dm_reply_ref := Some fallback_reply
            | `Player ->
                player_fallback_count := !player_fallback_count + 1);
            appended_events := !appended_events @ [ reply_event ];
            let* action_events =
              match role with
              | `Dm ->
                  let payload =
                    `Assoc
                      [
                        ("phase", `String phase);
                        ("turn", `Int turn_before);
                        ("role", `String "dm");
                        ("actor_id", `String actor_id);
                        ("keeper", `String keeper_name);
                        ("narration", `String fallback_reply);
                        ("is_fallback", `Bool true);
                      ]
                  in
                  let* event =
                    append_event ~base_dir ~room_id
                      ~event_type:Trpg_engine_event.Narration_posted
                      ~actor_id ~payload ()
                  in
                  Ok [ event ]
              | `Player ->
                  let payload =
                    `Assoc
                      [
                        ("phase", `String phase);
                        ("turn", `Int turn_before);
                        ("role", `String "player");
                        ("actor_id", `String actor_id);
                        ("keeper", `String keeper_name);
                        ("narration", `String fallback_reply);
                        ("is_fallback", `Bool true);
                      ]
                  in
                  let* event =
                    append_event ~base_dir ~room_id
                      ~event_type:Trpg_engine_event.Narration_posted
                      ~actor_id ~payload ()
                  in
                  Ok [ event ]
            in
            appended_events := !appended_events @ action_events;
            let* pressure_events =
              match role with
              | `Dm ->
                  append_npc_counterattack_events ~base_dir ~room_id ~phase
                    ~turn:turn_before ~state:state_for_pressure
              | `Player -> Ok []
            in
            appended_events := !appended_events @ pressure_events;
            statuses :=
              `Assoc
                [
                  ("actor_id", `String actor_id);
                  ("role", `String (role_to_string role));
                  ("keeper", `String keeper_name);
                  ("status", `String "fallback");
                  ("stage", `String stage);
                  ("reason", `String reason);
                  ("reply", `String fallback_reply);
                ]
              :: !statuses;
            Ok ()
        in
        (* Phase 1: BDI state update after successful keeper reply.
           Observation-only — errors are logged but never block the main path. *)
        let update_bdi_after_reply ~reply_text ~sa =
          let room_dir = Filename.concat base_dir room_id in
          let bdi0 = Trpg_bdi.load ~room_dir ~actor_id in
          let bdi1 = Trpg_bdi.decay_beliefs ~current_turn:turn_before bdi0 in
          (* Update belief: the keeper's reply reflects what the character now knows *)
          let belief_subject =
            Printf.sprintf "turn_%d_action" turn_before
          in
          let belief_content =
            let max_len = 120 in
            if String.length reply_text <= max_len then reply_text
            else String.sub reply_text 0 max_len ^ "..."
          in
          let bdi2 =
            Trpg_bdi.update_belief
              ~subject:belief_subject
              ~content:belief_content
              ~confidence:0.9
              ~turn:turn_before
              bdi1
          in
          (* Update desire based on action type *)
          let bdi3 =
            match sa.sa_type with
            | Attack | Defend ->
                Trpg_bdi.update_desire
                  ~goal:"survive combat" ~priority:0.9 ~category:"survival" bdi2
            | Heal ->
                Trpg_bdi.update_desire
                  ~goal:"recover health" ~priority:0.8 ~category:"survival" bdi2
            | Social ->
                Trpg_bdi.update_desire
                  ~goal:"build relationships" ~priority:0.6 ~category:"social" bdi2
            | Investigate | Explore ->
                Trpg_bdi.update_desire
                  ~goal:"discover information" ~priority:0.7 ~category:"quest" bdi2
            | QuestUpdate ->
                Trpg_bdi.update_desire
                  ~goal:"advance quest" ~priority:0.8 ~category:"quest" bdi2
            | Magic | UseItem | SetFlag | SceneTransition -> bdi2
          in
          (* Save BDI state — ignore errors (observation-only) *)
          let _save_result = Trpg_bdi.save ~room_dir bdi3 in
          (* Emit Bdi_updated event — ignore errors *)
          let _event_result =
            append_event ~base_dir ~room_id
              ~event_type:Trpg_engine_event.Bdi_updated
              ~actor_id
              ~payload:(Trpg_bdi.to_yojson bdi3)
              ()
          in
          ()
        in
        (* Phase 2: Harness evaluation after successful keeper reply.
           Observation-only — errors are logged but never block the main path.
           Tier 1 (structural gate): cheap model, ~50 tokens.
           Tier 2 (quality scoring): capable model, ~200 tokens. *)
        let evaluate_keeper_response ~reply_text =
          (* Opt-in only: skip evaluation when no model is configured.
             Prevents CI hang — LLM HTTP calls block indefinitely
             when the endpoint (e.g. Ollama) is unreachable. *)
          match Sys.getenv_opt "TRPG_HARNESS_TIER1_MODEL" with
          | None -> ()
          | Some tier1_str ->
          try
            let tier1_model =
              match Llm_client.model_spec_of_string tier1_str with
              | Ok m -> m
              | Error _ -> Llm_client.ollama_lfm
            in
            let tier2_model =
              match Sys.getenv_opt "TRPG_HARNESS_TIER2_MODEL" with
              | Some s -> (
                  match Llm_client.model_spec_of_string s with
                  | Ok m -> m
                  | Error _ -> Llm_client.glm_cloud)
              | None -> Llm_client.glm_cloud
            in
            let pctx =
              extract_prompt_context ~actor_id ~dm_persona_override state_json
            in
            let actor_persona =
              match role with
              | `Dm -> "Dungeon Master"
              | `Player -> pctx.actor_persona
            in
            let scene_context =
              let recent = String.concat "\n" pctx.narrative_recent in
              Printf.sprintf "Scene: %s (%s)\n%s"
                pctx.scene_description pctx.scene_mood recent
            in
            let result =
              Trpg_harness.evaluate
                ~tier1_model ~tier2_model
                ~actor_name:pctx.actor_name
                ~actor_persona
                ~actor_traits:pctx.actor_traits
                ~scene_context
                ~response_text:reply_text
            in
            let _event_result =
              append_event ~base_dir ~room_id
                ~event_type:Trpg_engine_event.Evaluation_scored
                ~actor_id
                ~payload:(Trpg_harness.result_to_yojson result)
                ()
            in
            ()
          with exn ->
            let _ignore =
              Printf.eprintf
                "[harness] evaluate_keeper_response failed for %s: %s\n%!"
                actor_id (Printexc.to_string exn)
            in
            ()
        in
        let lease_check =
          match role with
          | `Dm -> Ok ()
          | `Player -> (
              match owner_for_actor state actor_id with
              | Some owner when normalize_keeper_name owner <> "auto-pilot"
                            && normalize_keeper_name owner <> normalize_keeper_name keeper_name ->
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
        | Error lease_error ->
            record_unavailable_status
              ~status:"lease_denied"
              ~error:lease_error
              ~stage:"lease_check"
        | Ok () ->
        let base_prompt =
          build_keeper_prompt
            ~dm_persona_override
            ~room_id
            ~phase
            ~turn:turn_before
            ~role
            ~actor_id
            ~state_json
            ~lang:prompt_lang
        in
        let synthesized_roleplay_reply () =
          match role with
          | `Player -> fallback_player_reply ~state:state_json ~actor_id
          | `Dm -> fallback_dm_reply ~state:state_json
        in
        let normalize_reply_with_action reply sa =
          let trimmed_reply = String.trim reply in
          let candidate_reply =
            if trimmed_reply = "" || is_placeholder_reply trimmed_reply then
              String.trim sa.description
            else trimmed_reply
          in
          let normalized_reply0 =
            if candidate_reply = "" || is_placeholder_reply candidate_reply then
              String.trim (synthesized_roleplay_reply ())
            else candidate_reply
          in
          let recent_replies =
            recent_actor_replies ~state:state_json ~actor_id ~limit:3
          in
          let normalized_reply =
            let normalized_current =
              normalize_reply_for_comparison normalized_reply0
            in
            let is_repeated =
              normalized_current <> ""
              && List.exists
                   (fun recent ->
                     normalize_reply_for_comparison recent = normalized_current)
                   recent_replies
            in
            if not is_repeated then normalized_reply0
            else
              let alternate = String.trim (synthesized_roleplay_reply ()) in
              if alternate = "" then normalized_reply0
              else
                let normalized_alt = normalize_reply_for_comparison alternate in
                let alt_repeated =
                  normalized_alt <> ""
                  && List.exists
                       (fun recent ->
                         normalize_reply_for_comparison recent = normalized_alt)
                       recent_replies
                in
                if alt_repeated then normalized_reply0 else alternate
          in
          let normalized_description =
            let desc = String.trim sa.description in
            if desc = "" || is_placeholder_reply desc then normalized_reply else desc
          in
          (normalized_reply, { sa with description = normalized_description })
        in
        let validate_keeper_payload keeper_json =
          let ( let* ) = Result.bind in
          let* reply =
            match parse_keeper_reply keeper_json with
            | Ok value -> Ok value
            | Error e -> Error (`Schema e)
          in
          let* sa = parse_and_validate_structured_action ~role keeper_json in
          let normalized_reply, normalized_sa =
            normalize_reply_with_action reply sa
          in
          if normalized_reply = "" then
            Error (`Schema "reply is empty after cleanup")
          else Ok (normalized_reply, normalized_sa)
        in
        let synthetic_action_for_reply reply_text =
          match infer_action_type_from_narrative ~role reply_text with
          | Some sa -> sa
          | None -> (
              match role with
              | `Player ->
                  {
                    sa_type = Attack;
                    target_id = None;
                    description = reply_text;
                    flag_key = None;
                    scene = None;
                    quest_info = None;
                    memory_hint = None;
                    raw_payload =
                      `Assoc
                        [
                          ("type", `String "attack");
                          ("description", `String reply_text);
                          ("inferred", `Bool true);
                          ("source", `String "synthetic_fallback");
                        ];
                  }
              | `Dm ->
                  {
                    sa_type = SetFlag;
                    target_id = None;
                    description = reply_text;
                    flag_key = Some "story.recovered";
                    scene = None;
                    quest_info = None;
                    memory_hint = None;
                    raw_payload =
                      `Assoc
                        [
                          ("type", `String "set_flag");
                          ("description", `String reply_text);
                          ("flag_key", `String "story.recovered");
                          ("inferred", `Bool true);
                          ("source", `String "synthetic_fallback");
                        ];
                  })
        in
        let infer_action_from_keeper_json keeper_json =
          let mk_result ~reason reply_text =
            let seed_reply =
              let trimmed = String.trim reply_text in
              if trimmed = "" || is_reply_noise_text trimmed then
                String.trim (synthesized_roleplay_reply ())
              else trimmed
            in
            let synthetic_action = synthetic_action_for_reply seed_reply in
            let normalized_reply, normalized_sa =
              normalize_reply_with_action seed_reply synthetic_action
            in
            if normalized_reply = "" then None
            else Some (normalized_reply, normalized_sa, reason)
          in
          match parse_keeper_reply keeper_json with
          | Ok reply_text -> mk_result ~reason:"keeper_reply_inferred" reply_text
          | Error _ ->
              mk_result
                ~reason:"keeper_reply_synthesized"
                (synthesized_roleplay_reply ())
        in
        let re_prompt_message ~stage ~reason =
          Printf.sprintf
            "%s\n\n[RETRY REQUIRED]\n\
             Your previous response was rejected at stage=%s (%s).\n\
             Return concise in-world narrative plus exactly one valid structured_action JSON line."
            base_prompt stage
            (compact_summary_text ~max_len:180 reason)
        in
        let run_keeper_once ~stage ~message =
          match
            call_keeper ctx ~name:keeper_name ~message
              ~timeout_sec:keeper_timeout_sec
          with
          | `Timeout -> Error (`Timeout stage)
          | `Error err -> Error (`Unavailable (stage, err))
          | `Ok keeper_json -> (
              match validate_keeper_payload keeper_json with
              | Ok (reply, sa) -> Ok (reply, sa)
              | Error validation_error -> Error (`Validation (stage, validation_error, keeper_json))
          )
        in
        let keeper_result = run_keeper_once ~stage:"masc_keeper_msg" ~message:base_prompt in
        let keeper_result =
          match keeper_result with
          | Error (`Validation (_stage, validation_error, keeper_json)) -> (
              match infer_action_from_keeper_json keeper_json with
              | Some (reply_text, inferred_sa, inferred_reason) ->
                  statuses :=
                    `Assoc
                      [
                        ("actor_id", `String actor_id);
                        ("role", `String (role_to_string role));
                        ("keeper", `String keeper_name);
                        ("status", `String "inferred_pre_reprompt");
                        ("reason", `String inferred_reason);
                        ( "validation_error",
                          `String
                            (string_of_structured_action_validation_error
                               validation_error) );
                        ("action_type", `String (string_of_action_type inferred_sa.sa_type));
                        ("reply", `String reply_text);
                      ]
                    :: !statuses;
                  Ok (reply_text, inferred_sa)
              | None ->
                  reprompt_count := !reprompt_count + 1;
                  (match validation_error with
                  | `Schema _ -> schema_failures := !schema_failures + 1
                  | `Rule _ ->
                      rule_validation_failures := !rule_validation_failures + 1);
                  let stage = structured_action_error_kind validation_error in
                  let reason = structured_action_error_message validation_error in
                  statuses :=
                    `Assoc
                      [
                        ("actor_id", `String actor_id);
                        ("role", `String (role_to_string role));
                        ("keeper", `String keeper_name);
                        ("status", `String "re_prompt");
                        ("stage", `String stage);
                        ("reason", `String reason);
                        ("attempt", `Int 1);
                      ]
                    :: !statuses;
                  let retry_prompt = re_prompt_message ~stage ~reason in
                  run_keeper_once ~stage:"re_prompt" ~message:retry_prompt)
          | other -> other
        in
        match keeper_result with
        | Error (`Timeout stage) ->
            let* timeout_event, unavailable_result =
              append_timeout_and_unavailable_events
                ~base_dir
                ~room_id
              ~phase
              ~turn:turn_before
              ~role
              ~actor_id
              ~keeper_name
              ~timeout_sec:keeper_timeout_sec
              ~sampling_state:unavailable_sampling
            in
            timeout_count := !timeout_count + 1;
            appended_events := !appended_events @ [ timeout_event ];
            let sampled, sampled_reason =
              match unavailable_result with
              | `Appended unavailable_event ->
                  unavailable_count := !unavailable_count + 1;
                  appended_events := !appended_events @ [ unavailable_event ];
                  (false, None)
              | `Sampled reason -> (true, Some reason)
            in
            statuses :=
              `Assoc
                [
                  ("actor_id", `String actor_id);
                  ("role", `String (role_to_string role));
                  ("keeper", `String keeper_name);
                  ("status", `String "timeout");
                  ("reason", `String "timeout");
                  ("stage", `String stage);
                  ("timeout_sec", `Float keeper_timeout_sec);
                  ("sampled", `Bool sampled);
                  ( "sampled_reason",
                    Option.fold ~none:`Null ~some:(fun v -> `String v)
                      sampled_reason );
                ]
              :: !statuses;
            if local_fallback then
              let* () =
                apply_local_fallback ~stage:"timeout_fallback" ~reason:"timeout"
              in
              Ok ()
            else Ok ()
        | Error (`Unavailable (stage, keeper_error)) ->
            let* () =
              record_unavailable_status
                ~status:"unavailable"
                ~error:keeper_error
                ~stage
            in
            if local_fallback then
              apply_local_fallback ~stage:"keeper_call_fallback"
                ~reason:keeper_error
            else Ok ()
        | Error (`Validation (stage, validation_error, keeper_json)) ->
            (match validation_error with
            | `Schema _ -> schema_failures := !schema_failures + 1
            | `Rule _ ->
                rule_validation_failures := !rule_validation_failures + 1);
            let validation_error_msg =
              string_of_structured_action_validation_error validation_error
            in
            (* Server-side narrative inference: extract action from free-form text *)
            let inferred =
              match parse_keeper_reply keeper_json with
              | Ok reply_text ->
                  (match infer_action_type_from_narrative ~role reply_text with
                  | Some sa -> Some (reply_text, sa)
                  | None -> None)
              | Error _ -> None
            in
            (match inferred with
            | Some (reply_text, sa) ->
                let* reply_event =
                  append_keeper_reply_event
                    ~base_dir ~room_id ~phase ~turn:turn_before
                    ~role ~actor_id ~keeper_name ~reply:reply_text
                in
                success_count := !success_count + 1;
                (match role with
                | `Dm ->
                    dm_success := true;
                    dm_reply_ref := Some reply_text
                | `Player -> player_success_count := !player_success_count + 1);
                appended_events := !appended_events @ [ reply_event ];
                let* action_events =
                  apply_structured_action ~base_dir ~room_id
                    ~turn:turn_before ~phase ~actor_id ~state:state_json sa
                in
                appended_events := !appended_events @ action_events;
                (* Phase 1: Update BDI state after inferred reply *)
                update_bdi_after_reply ~reply_text ~sa;
                (* Phase 2: Harness evaluation — observation-only *)
                evaluate_keeper_response ~reply_text;
                statuses :=
                  `Assoc
                    [
                      ("actor_id", `String actor_id);
                      ("role", `String (role_to_string role));
                      ("keeper", `String keeper_name);
                      ("status", `String "inferred");
                      ("reply", `String reply_text);
                      ("action_type", `String (string_of_action_type sa.sa_type));
                    ]
                  :: !statuses;
                Ok ()
            | None ->
                let status_name =
                  match validation_error with
                  | `Schema _ -> "schema_invalid"
                  | `Rule _ -> "rule_invalid"
                in
                let* () =
                  record_unavailable_status
                    ~status:status_name
                    ~error:validation_error_msg
                    ~stage
                in
                apply_local_fallback ~stage:"validation_fallback"
                  ~reason:validation_error_msg)
        | Ok (reply, sa) ->
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
            (match role with
            | `Dm ->
                dm_success := true;
                dm_reply_ref := Some reply
            | `Player -> player_success_count := !player_success_count + 1);
            appended_events := !appended_events @ [ reply_event ];
            let* action_events =
              apply_structured_action ~base_dir ~room_id
                ~turn:turn_before ~phase ~actor_id ~state:state_json sa
            in
            appended_events := !appended_events @ action_events;
            let memory_status_fields =
              memory_status_fields_of_action_events action_events
            in
            (* Phase 1: Update BDI state after successful reply *)
            update_bdi_after_reply ~reply_text:reply ~sa;
            (* Phase 2: Harness evaluation — observation-only *)
            evaluate_keeper_response ~reply_text:reply;
            statuses :=
              `Assoc
                ([
                   ("actor_id", `String actor_id);
                   ("role", `String (role_to_string role));
                   ("keeper", `String keeper_name);
                   ("status", `String "ok");
                   ("reply", `String reply);
                   ("action_type", `String (string_of_action_type sa.sa_type));
                 ]
                @ memory_status_fields)
              :: !statuses;
            Ok ()
      in

      let* () =
        List.fold_left
          (fun acc (actor_id, keeper_name) ->
            let* () = acc in
            process_one
              ~state_json:!state_for_players_ref
              ~role:`Player ~actor_id ~keeper_name)
          (Ok ())
          live_player_keepers
      in
      let player_required_successes =
        let total = active_player_count in
        if total <= 0 then 0 else max 1 ((total + 1) / 2)
      in
      let player_quorum_met =
        active_player_count > 0
        && !player_success_count + !player_fallback_count >= player_required_successes
      in
      let state_for_dm_prompt =
        if player_quorum_met then
          match derive_state ~base_dir ~room_id ~rule_module with
          | Ok derived_after_players ->
              inject_interventions_into_state
                (state_of_derived derived_after_players)
                interventions_applied
              |> compact_state_for_prompt
          | Error _ -> !state_for_players_ref
        else !state_for_players_ref
      in
      let* () =
        if player_quorum_met then
          process_one
            ~state_json:state_for_dm_prompt
            ~role:`Dm ~actor_id:"dm" ~keeper_name:dm_keeper
        else (
          statuses :=
            `Assoc
              [
                ("actor_id", `String "dm");
                ("role", `String "dm");
                ("keeper", `String dm_keeper);
                ("status", `String "skipped");
                ( "reason",
                  `String
                    (Printf.sprintf
                       "player quorum not met: success=%d fallback=%d required=%d; dm execution skipped"
                       !player_success_count !player_fallback_count
                       player_required_successes) );
                ("stage", `String "player_quorum");
              ]
            :: !statuses;
          Ok () )
      in
      let* () =
        if phase = "round" && player_quorum_met && !dm_success then
          let existing_npc_attacks = count_npc_attacks_in_list !appended_events in
          if existing_npc_attacks > 0 then Ok ()
          else
            let state_for_pressure =
              match derive_state ~base_dir ~room_id ~rule_module with
              | Ok derived_after_dm ->
                  inject_interventions_into_state
                    (state_of_derived derived_after_dm)
                    interventions_applied
              | Error _ -> state_for_dm_prompt
            in
            let* pressure_events =
              append_npc_counterattack_events ~base_dir ~room_id ~phase
                ~turn:turn_before ~state:state_for_pressure
            in
            appended_events := !appended_events @ pressure_events;
            Ok ()
        else Ok ()
      in
      let advanced = player_quorum_met && !dm_success in
      let turn_after = if advanced then next_turn else turn_before in
      let* () =
        if advanced then
          let* turn_event =
            append_event
              ~base_dir
              ~room_id
              ~event_type:Trpg_engine_event.Turn_started
              ~payload:(`Assoc [ ("turn", `Int next_turn) ])
              ()
          in
          appended_events := !appended_events @ [ turn_event ];
          Ok ()
        else Ok ()
      in
      let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
      let next_state = state_of_derived next_derived in
      let computed_outcome =
        if outcome_already_emitted then None
        else
          match
            evaluate_session_outcome ~end_rules ~state:next_state
              ~dm_reply:!dm_reply_ref
          with
          | Some _ as outcome -> outcome
          | None ->
              let stagnation_threshold = 5 in
              let all_events =
                match
                  Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
                with
                | Ok evs -> evs
                | Error _ -> []
              in
              let all_events = all_events @ !appended_events in
              if detect_stagnation ~events:all_events ~threshold:stagnation_threshold
              then Some (Draw, "stagnation")
              else None
      in
      let* final_derived =
        match computed_outcome with
        | None -> Ok next_derived
        | Some (outcome, reason) ->
            let outcome_str = string_of_session_outcome outcome in
            let summary = summary_of_session_outcome outcome in
            let room_end_payload =
              `Assoc
                [
                  ("room_id", `String room_id);
                  ("reason", `String reason);
                  ("outcome", `String outcome_str);
                ]
            in
            let outcome_payload =
              `Assoc
                [
                  ("outcome", `String outcome_str);
                  ("reason", `String reason);
                  ("summary", `String summary);
                  ("turn", `Int turn_after);
                  ("phase", `String phase);
                ]
            in
            let* room_end_event_opt =
              if room_already_ended then Ok None
              else
                let* room_end_event =
                  append_event ~base_dir ~room_id
                    ~event_type:Trpg_engine_event.Room_ended
                    ~payload:room_end_payload ()
                in
                Ok (Some room_end_event)
            in
            let* outcome_event =
              append_event ~base_dir ~room_id
                ~event_type:Trpg_engine_event.Session_outcome
                ~payload:outcome_payload ()
            in
            (match room_end_event_opt with
            | Some room_end_event ->
                appended_events := !appended_events @ [ room_end_event ]
            | None -> ());
            appended_events := !appended_events @ [ outcome_event ];
            let importance_score =
              match outcome with
              | Victory -> 92
              | Defeat -> 88
              | Draw -> 72
            in
            let* memory_event =
              append_memory_signal_event ~base_dir ~room_id ~event_tier:"long"
                ~importance_score
                ~summary_ko:(Printf.sprintf "세션 결과 확정: %s (%s)" outcome_str reason)
                ~summary_en:(Printf.sprintf "Session outcome finalized: %s (%s)" outcome_str reason)
                ~entity_refs:
                  [
                    ("outcome", `String outcome_str);
                    ("reason", `String reason);
                    ("turn", `Int turn_after);
                  ]
            in
            appended_events := !appended_events @ [ memory_event ];
            latest_outcome_payload := Some outcome_payload;
            derive_state ~base_dir ~room_id ~rule_module
      in
      let* _final_derived, final_state =
        let state_after_outcome = state_of_derived final_derived in
        let room_status =
          match state_after_outcome |> member "status" with
          | `String status -> String.lowercase_ascii status
          | _ -> "active"
        in
        if room_status = "ended" then Ok (final_derived, state_after_outcome)
        else
          let* join_window_opened_event =
            append_event
              ~base_dir
              ~room_id
              ~event_type:Trpg_engine_event.Join_window_opened
              ~payload:
                (`Assoc
                  [
                    ("turn", `Int turn_after);
                    ("window", `String "round_boundary_only");
                    ("reason", `String "round_run_completed");
                  ])
              ()
          in
          appended_events := !appended_events @ [ join_window_opened_event ];
          let* reopened_derived = derive_state ~base_dir ~room_id ~rule_module in
          Ok (reopened_derived, state_of_derived reopened_derived)
      in
      let canon_check =
        let session_events_after = existing_events_before @ !appended_events in
        evaluate_canon_check ~base_dir ~state:final_state
          ~events:session_events_after ~dm_reply:!dm_reply_ref
      in
      let* canon_events =
        append_canon_check_observability_events ~base_dir ~room_id
          ~turn:turn_after ~phase ~check:canon_check
      in
      appended_events := !appended_events @ canon_events;
      let statuses = List.rev !statuses in
      let progress_detail = status_first_non_ok_detail statuses in
      let progress_reason =
        if advanced then "advanced"
        else if !timeout_count > 0 then "timeout"
        else if !schema_failures > 0 || !rule_validation_failures > 0 then
          "structured_action_invalid"
        else if !unavailable_count > 0 then "keeper_unavailable"
        else if not player_quorum_met then "player_quorum_not_met"
        else if not !dm_success then "dm_not_resolved"
        else if !fallback_count > 0 then "fallback_applied_no_progress"
        else "stalled"
      in
      let recovery_applied = !fallback_count > 0 in
      let recovery_mode =
        if recovery_applied then "local_fallback_applied"
        else if local_fallback then "local_fallback_enabled"
        else "none"
      in
      let roll_audit_all = build_round_roll_audit !appended_events in
      let roll_audit_count = List.length roll_audit_all in
      let roll_audit = take_first_n 8 roll_audit_all in
      let memory_signal_count, memory_guardrail_escalations =
        memory_observability_from_events !appended_events
      in
      let npc_spawned =
        count_event_type_in_list Trpg_engine_event.Actor_spawned !appended_events
      in
      let npc_attacks = count_npc_attacks_in_list !appended_events in
      let dm_style =
        match base_state_for_prompt |> member "config" with
        | `Assoc fields -> (
            match List.assoc_opt "dm" fields with
            | Some dm_json -> get_string_field dm_json "style"
            | None -> "")
        | _ -> ""
      in
      let dm_persona_used =
        infer_dm_persona_id
          ~explicit:(Option.bind dm_persona_override dm_persona_id_of_string)
          ~dm_style
      in
      let events_json = List.map Trpg_engine_event.to_yojson !appended_events in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("phase", `String phase);
            ("turn_before", `Int turn_before);
            ("turn_after", `Int turn_after);
            ("timeout_sec", `Float timeout_sec);
            ( "preflight_warning",
              match preflight_warning with
              | Some warning -> `String warning
              | None -> `Null );
            ("statuses", `List statuses);
            ("interventions_applied", `List interventions_applied);
            ( "summary",
              `Assoc
                [
                  ("participants", `Int (1 + active_player_count));
                  ("successes", `Int !success_count);
                  ("fallbacks", `Int !fallback_count);
                  ("player_successes", `Int !player_success_count);
                  ("player_fallbacks", `Int !player_fallback_count);
                  ("player_required_successes", `Int player_required_successes);
                  ("player_quorum_met", `Bool player_quorum_met);
                  ("dm_success", `Bool !dm_success);
                  ("advanced", `Bool advanced);
                  ("progress_reason", `String progress_reason);
                  ( "progress_detail",
                    match progress_detail with
                    | Some detail -> `String detail
                    | None -> `Null );
                  ("recovery_applied", `Bool recovery_applied);
                  ("recovery_mode", `String recovery_mode);
                    ("effective_timeout_sec", `Float timeout_sec);
                    ("requested_timeout_sec", `Float timeout_sec);
                    ("keeper_timeout_sec", `Float keeper_timeout_sec);
                  ("timeouts", `Int !timeout_count);
                  ("unavailable", `Int !unavailable_count);
                  ("schema_failures", `Int !schema_failures);
                  ("rule_validation_failures", `Int !rule_validation_failures);
                  ("reprompts", `Int !reprompt_count);
                  ("dm_persona", `String (string_of_dm_persona_id dm_persona_used));
                  ("dm_persona_overridden", `Bool (Option.is_some dm_persona_override));
                  ("npc_spawned", `Int npc_spawned);
                  ("npc_attacks", `Int npc_attacks);
                  ("interventions", `Int (List.length interventions_applied));
                  ("canon_status", `String canon_check.status);
                  ("canon_violation_count", `Int (List.length canon_check.violations));
                  ("canon_warning_count", `Int (List.length canon_check.warnings));
                  ("memory_signals", `Int memory_signal_count);
                  ("memory_guardrail_escalations", `Int memory_guardrail_escalations);
                  ("roll_audit_count", `Int roll_audit_count);
                  ("roll_audit", `List roll_audit);
                ] );
            ("canon_check", canon_check_to_yojson canon_check);
            ( "outcome",
              match !latest_outcome_payload with
              | Some payload -> payload
              | None -> `Null );
            ("events", `List events_json);
            ( "room_status",
              match final_state |> member "status" with
              | `String status -> `String status
              | _ -> `String "active" );
            ("state", final_state);
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
  | "masc_trpg_actor_update" -> Some (handle_actor_update ctx args)
  | "masc_trpg_actor_delete" -> Some (handle_actor_delete ctx args)
  | "masc_trpg_actor_claim" -> Some (handle_actor_claim ctx args)
  | "masc_trpg_actor_release" -> Some (handle_actor_release ctx args)
  | "masc_trpg_join_eligibility" -> Some (handle_join_eligibility ctx args)
  | "masc_trpg_mid_join_request" -> Some (handle_mid_join_request ctx args)
  | "masc_trpg_intervention_submit" -> Some (handle_intervention_submit ctx args)
  | "masc_trpg_round_run" -> Some (handle_round_run ctx args)
  | "masc_trpg_scene_transition" -> Some (handle_scene_transition ctx args)
  | "masc_trpg_quest_update" -> Some (handle_quest_update ctx args)
  | "masc_trpg_world_event" -> Some (handle_world_event ctx args)
  | _ -> None
