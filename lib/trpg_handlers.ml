(** Trpg_handlers — MCP tool handlers for dice rolls, turn advances,
    stream reads, actor management, join eligibility, interventions,
    and round audit helpers. *)

include Trpg_round
open Yojson.Safe.Util

let handle_dice_roll ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
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
        ~store
        ~room_id
        ~event_type:Trpg_engine_event.Dice_rolled
        ~actor_id
        ~payload
        ()
    in
    let* derived = derive_state ~store ~room_id ~rule_module in
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
  let store = ctx.store in
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
    let* derived = derive_state ~store ~room_id ~rule_module in
    let* current_turn = read_state_turn derived in
    let next_turn = max 1 (current_turn + 1) in
    let* turn_event =
      append_event
        ~store
        ~room_id
        ~event_type:Trpg_engine_event.Turn_started
        ~payload:(`Assoc [ ("turn", `Int next_turn) ])
        ()
    in
    let* join_window_event =
      append_event
        ~store
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
              ~store
              ~room_id
              ~event_type:Trpg_engine_event.Phase_changed
              ~payload:(`Assoc [ ("phase", `String p) ])
              ()
          in
          Ok (Some ev)
    in
    let* next_derived = derive_state ~store ~room_id ~rule_module in
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
  let store = ctx.store in
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
        store.read_events_after ~room_id ~after_seq
      else store.read_events ~room_id
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
  let now_ms = int_of_float (Time_compat.now () *. 1000.0) in
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

let append_pending_interventions ~(store : Trpg_store.t) ~room_id ~phase ~turn =
  let ( let* ) = Result.bind in
  let* events = store.read_events ~room_id in
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
          append_event ~store ~room_id
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
      let* catalog = ctx.store.load_catalog () in
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
    let* catalog = ctx.store.load_catalog () in
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
  let store = ctx.store in
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
        append_event ~store ~room_id
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
  let store = ctx.store in
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
    let* catalog = store.Trpg_store.load_catalog () in
    let* dm_preset = resolve_dm_preset ~seed:fallback_seed catalog dm_preset_id in
    let* world_preset =
      (* +19 offset decorrelates world preset selection from DM selection *)
      resolve_world_preset ~seed:(fallback_seed + 19) catalog world_preset_id
    in
    let* world_contract =
      resolve_world_contract_for_session ~store
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
      store.read_events ~room_id
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
      append_event ~store ~room_id
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
      append_event ~store ~room_id
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
      append_event ~store ~room_id
        ~event_type:Trpg_engine_event.Party_selected
        ~actor_id:ctx.agent_name ~payload:party_selected_payload ()
    in
    let* phase_event =
      append_event ~store ~room_id
        ~event_type:Trpg_engine_event.Phase_changed
        ~payload:(`Assoc [ ("phase", `String phase) ])
        ()
    in
    let* room_started =
      append_event ~store ~room_id
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

let handle_join_eligibility ctx args : result =
  let ( let* ) = Result.bind in
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name_opt = get_optional_string args "keeper_name" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let* events = store.read_events ~room_id in
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
  let store = ctx.store in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* keeper_name = get_required_string args "keeper_name" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* derived = derive_state ~store ~room_id ~rule_module in
    let state = state_of_derived derived in
    let* events = store.read_events ~room_id in
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
      append_event ~store ~room_id
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
        append_event ~store ~room_id
          ~event_type:Trpg_engine_event.Mid_join_rejected ~actor_id
          ~payload:rejected_payload ()
      in
      let* memory_event =
        append_memory_signal_event ~store ~room_id ~event_tier:"short"
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
      let* next_derived = derive_state ~store ~room_id ~rule_module in
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
            append_event ~store ~room_id
              ~event_type:Trpg_engine_event.Actor_spawned ~actor_id
              ~payload:spawn_payload ()
          in
          let* d = derive_state ~store ~room_id ~rule_module in
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
                  append_event ~store ~room_id
                    ~event_type:Trpg_engine_event.Actor_claimed ~actor_id
                    ~payload:claim_payload ()
                in
                let* d = derive_state ~store ~room_id ~rule_module in
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
                append_event ~store ~room_id
                  ~event_type:Trpg_engine_event.Actor_updated ~actor_id
                  ~payload ()
              in
              let* d = derive_state ~store ~room_id ~rule_module in
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
            append_event ~store ~room_id
              ~event_type:Trpg_engine_event.Mid_join_granted ~actor_id
              ~payload:granted_payload ()
          in
          let* memory_event =
            append_memory_signal_event ~store ~room_id ~event_tier:"mid"
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
          let* final_derived = derive_state ~store ~room_id ~rule_module in
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
  let store = ctx.store in
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
        (Int64.of_float (Time_compat.now () *. 1000.0))
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
      append_event ~store ~room_id
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

let status_non_ok_detail (status_json : Yojson.Safe.t) : string option =
  let status_name =
    status_json |> member "status" |> to_string_option
    |> Option.value ~default:""
    |> String.trim |> String.lowercase_ascii
  in
  if status_name = "" || status_name = "ok" then None
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

let status_first_non_ok_detail (statuses : Yojson.Safe.t list) : string option =
  let rec loop = function
    | [] -> None
    | status_json :: tl -> (
        match status_non_ok_detail status_json with
        | Some detail -> Some detail
        | None -> loop tl )
  in
  loop statuses

let status_first_non_ok_detail_for_role ~role (statuses : Yojson.Safe.t list) :
    string option =
  let wanted_role = String.lowercase_ascii (String.trim role) in
  let rec loop = function
    | [] -> None
    | status_json :: tl ->
        let role_name =
          status_json |> member "role" |> to_string_option
          |> Option.value ~default:""
          |> String.trim |> String.lowercase_ascii
        in
        if role_name <> wanted_role then loop tl
        else
          match status_non_ok_detail status_json with
          | Some detail -> Some detail
          | None -> loop tl
  in
  loop statuses

let status_non_ok_detail_list_for_role ~role ~max_items
    (statuses : Yojson.Safe.t list) : string list =
  let wanted_role = String.lowercase_ascii (String.trim role) in
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | status_json :: tl ->
        let role_name =
          status_json |> member "role" |> to_string_option
          |> Option.value ~default:""
          |> String.trim |> String.lowercase_ascii
        in
        if role_name <> wanted_role then loop acc remaining tl
        else
          match status_non_ok_detail status_json with
          | Some detail -> loop (detail :: acc) (remaining - 1) tl
          | None -> loop acc remaining tl
  in
  loop [] max_items statuses

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

