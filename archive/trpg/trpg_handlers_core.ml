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
