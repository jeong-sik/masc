open Masc_mcp

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let make_temp_dir () =
  let dir = Filename.temp_file "test_tool_trpg_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755
  )

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let write_world_contracts_json base_dir content =
  let dir = Filename.concat base_dir "config/trpg" in
  ensure_dir dir;
  write_file (Filename.concat dir "world_contracts.json") content

let keeper_payload ?(action_type = "explore") ?target_id ?flag_key ?scene
    ?quest_info ?memory_hint_tier ?memory_hint_reason ?memory_hint_importance
    reply =
  let optional_string_field key value =
    match value with Some v -> [ (key, `String v) ] | None -> []
  in
  let memory_hint_field =
    match memory_hint_tier with
    | None -> []
    | Some tier ->
        let details =
          [ ("tier", `String tier) ]
          @
          (match memory_hint_reason with
          | Some reason -> [ ("reason", `String reason) ]
          | None -> [])
          @
          (match memory_hint_importance with
          | Some importance -> [ ("importance_score", `Int importance) ]
          | None -> [])
        in
        [ ("memory_hint", `Assoc details) ]
  in
  `Assoc
    [
      ("reply", `String reply);
      ( "structured_action",
        `Assoc
          ([ ("type", `String action_type); ("description", `String reply) ]
          @ optional_string_field "target_id" target_id
          @ optional_string_field "flag_key" flag_key
          @ optional_string_field "scene" scene
          @ optional_string_field "quest_info" quest_info
          @ memory_hint_field) );
    ]

let bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids =
  let party =
    `Assoc
      (List.map
         (fun id ->
           ( id,
             `Assoc
               [
                 ("name", `String id);
                 ("role", `String "player");
                 ("hp", `Int 1000);
                 ("max_hp", `Int 1000);
                 ("alive", `Bool true);
               ] ))
         actor_ids)
  in
  let config =
    `Assoc
      [
        ("party", party);
        ("world", `Assoc [ ("story_flags", `List []) ]);
        ("dm", `Assoc [ ("keeper_name", `String "dm-keeper") ]);
      ]
  in
  let room_created_payload =
    `Assoc
      [
        ("session_id", `String "test-session");
        ("rule_module", `String "dnd5e-lite");
        ("scenario_id", `String "test");
        ("dm_preset_id", `String "test");
        ("world_preset_id", `String "test");
        ("config", config);
      ]
  in
  let room_created =
    Trpg.Engine_event.make ~seq:1 ~room_id ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Room_created ~payload:room_created_payload ()
  in
  (match Trpg.Engine_store_sqlite.append_event ~base_dir ~event:room_created with
  | Ok () -> ()
  | Error e -> failwith ("bootstrap Room_created failed: " ^ e));
  let room_started =
    Trpg.Engine_event.make ~seq:2 ~room_id ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Room_started
      ~payload:(`Assoc [ ("phase", `String "round") ])
      ()
  in
  (match Trpg.Engine_store_sqlite.append_event ~base_dir ~event:room_started with
  | Ok () -> ()
  | Error e -> failwith ("bootstrap Room_started failed: " ^ e))

let append_event_exn ~base_dir ~(event : Trpg.Engine_event.t) =
  match Trpg.Engine_store_sqlite.append_event ~base_dir ~event with
  | Ok () -> ()
  | Error e -> failwith ("append event failed: " ^ e)

let append_room_event ~base_dir ~room_id ?actor_id ~event_type ~payload () =
  let next_seq =
    match Trpg.Engine_store_sqlite.read_events ~base_dir ~room_id with
    | Ok events -> List.length events + 1
    | Error _ -> 1
  in
  let event =
    Trpg.Engine_event.make ~seq:next_seq ~room_id ~ts:(Types.now_iso ())
      ~event_type ?actor_id ~payload ()
  in
  append_event_exn ~base_dir ~event

let dispatch_exn ctx ~name ~args =
  match Tool_trpg.dispatch ctx ~name ~args with
  | Some r -> r
  | None -> failwith ("dispatch returned None for " ^ name)

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let count_from_json json = json |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_round_run_success_path () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-success" ~actor_ids:["p1"; "p2"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Rain-soaked alley"
             "The scene opens in rain.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"attack" ~target_id:"npc-t1-01"
             "I scout ahead.")
    | "pk-2" ->
        `Ok
          (keeper_payload ~action_type:"defend" "I hold defensive line.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-success");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1"); ("p2", `String "pk-2") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int) "successes" 3 (Yojson.Safe.Util.member "successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "timeouts" 0 (Yojson.Safe.Util.member "timeouts" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "unavailable" 0 (Yojson.Safe.Util.member "unavailable" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check string) "progress_reason" "advanced"
    (Yojson.Safe.Util.member "progress_reason" summary |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "recovery_applied false" false
    (Yojson.Safe.Util.member "recovery_applied" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check string) "recovery_mode none" "none"
    (Yojson.Safe.Util.member "recovery_mode" summary |> Yojson.Safe.Util.to_string);
  Alcotest.(check (float 0.0001)) "effective_timeout_sec mirrors request" 1.0
    (Yojson.Safe.Util.member "effective_timeout_sec" summary |> Yojson.Safe.Util.to_float);
  Alcotest.(check int) "turn_after" 2 (Yojson.Safe.Util.member "turn_after" json |> Yojson.Safe.Util.to_int);

  let _, stream_all =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:(`Assoc [ ("room_id", `String "room-round-success") ])
  in
  let all_json = parse_json_exn stream_all in
  Alcotest.(check bool) "stream has events" true (count_from_json all_json >= 5);

  let _, stream_player =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-success");
            ("event_type", `String "turn.action.proposed");
          ])
  in
  let player_json = parse_json_exn stream_player in
  Alcotest.(check int) "player action proposed count" 2 (count_from_json player_json);

  let _, stream_resolved =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-success");
            ("event_type", `String "turn.action.resolved");
          ])
  in
  Alcotest.(check int)
    "turn.action.resolved count"
    3
    (count_from_json (parse_json_exn stream_resolved));

  let _, stream_dm =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-success");
            ("event_type", `String "narration.posted");
          ])
  in
  let dm_json = parse_json_exn stream_dm in
  Alcotest.(check int) "dm narration count" 1 (count_from_json dm_json);
  cleanup_dir base_dir

let test_round_run_memory_hint_guardrail_escalates_tier () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-memory-guardrail" ~actor_ids:["p1"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Narrow bridge"
             ~memory_hint_tier:"short"
             ~memory_hint_reason:"keep this lightweight"
             "The party crosses the narrow bridge.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"explore"
             "I scout the bridge perimeter.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-memory-guardrail");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let json = parse_json_exn body in
  let summary = json |> Yojson.Safe.Util.member "summary" in
  Alcotest.(check bool)
    "memory guardrail escalation counted"
    true
    ((summary |> Yojson.Safe.Util.member "memory_guardrail_escalations"
     |> Yojson.Safe.Util.to_int)
    >= 1);
  let dm_status =
    json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list
    |> List.find_opt (fun s ->
           s |> Yojson.Safe.Util.member "actor_id"
           |> Yojson.Safe.Util.to_string = "dm")
  in
  (match dm_status with
  | Some status_json ->
      Alcotest.(check string)
        "dm requested tier short"
        "short"
        (status_json |> Yojson.Safe.Util.member "memory_requested_tier"
        |> Yojson.Safe.Util.to_string);
      Alcotest.(check string)
        "dm effective tier escalated to mid"
        "mid"
        (status_json |> Yojson.Safe.Util.member "memory_effective_tier"
        |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool)
        "guardrail applied"
        true
        (status_json |> Yojson.Safe.Util.member "memory_guardrail_applied"
        |> Yojson.Safe.Util.to_bool)
  | None -> Alcotest.fail "dm status is missing");
  cleanup_dir base_dir

let test_round_run_canon_check_strict_failure () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  write_world_contracts_json base_dir
    {|{
  "default_contract_id": "strict-test",
  "contracts": [
    {
      "id": "strict-test",
      "title": "Strict Test Contract",
      "description": "Forces canon check failures for regression tests.",
      "required_flags": ["canon.required"],
      "forbidden_flags": ["canon.break"],
      "required_event_types": ["scene.transition"],
      "banned_terms": []
    }
  ]
}|};
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"set_flag" ~flag_key:"canon.break"
             "The DM forces a canon-breaking flag.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"explore"
             "I keep moving despite the anomaly.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let ok_start, start_body =
    dispatch_exn ctx ~name:"masc_trpg_session_start"
      ~args:
        (`Assoc
          [
            ("session_id", `String "session-canon-strict");
            ("dm_keeper", `String "dm-keeper");
            ("world_contract_id", `String "strict-test");
            ("canon_strict", `Bool true);
            ( "party",
              `List
                [
                  `Assoc
                    [
                      ("actor_id", `String "p1");
                      ("name", `String "Player One");
                      ("keeper_name", `String "pk-1");
                    ];
                ] );
          ])
  in
  Alcotest.(check bool) "session start ok" true ok_start;
  let start_json = parse_json_exn start_body in
  let room_id =
    start_json |> Yojson.Safe.Util.member "room_id" |> Yojson.Safe.Util.to_string
  in
  let player_keepers =
    start_json |> Yojson.Safe.Util.member "round_run_template"
    |> Yojson.Safe.Util.member "player_keepers"
  in
  let ok_round, round_body =
    dispatch_exn ctx ~name:"masc_trpg_round_run"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("dm_keeper", `String "dm-keeper");
            ("player_keepers", player_keepers);
            ("phase", `String "round");
            ("timeout_sec", `Float 1.0);
          ])
  in
  Alcotest.(check bool) "round_run succeeds with canon fail payload" true ok_round;
  let round_json = parse_json_exn round_body in
  let canon_check = round_json |> Yojson.Safe.Util.member "canon_check" in
  Alcotest.(check string)
    "canon status fail"
    "fail"
    (canon_check |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "canon has violations"
    true
    ((canon_check |> Yojson.Safe.Util.member "violations"
     |> Yojson.Safe.Util.to_list
     |> List.length)
    >= 1);
  let summary = round_json |> Yojson.Safe.Util.member "summary" in
  Alcotest.(check string)
    "summary canon status"
    "fail"
    (summary |> Yojson.Safe.Util.member "canon_status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "summary canon violation count >= 1"
    true
    ((summary |> Yojson.Safe.Util.member "canon_violation_count"
     |> Yojson.Safe.Util.to_int)
    >= 1);

  let _, stream_world_event =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("event_type", `String "world.event");
          ])
  in
  Alcotest.(check int)
    "world.event count includes canon check event"
    1
    (count_from_json (parse_json_exn stream_world_event));
  cleanup_dir base_dir

let test_round_run_canon_any_of_passes_with_flag_set () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  write_world_contracts_json base_dir
    {|{
  "default_contract_id": "canon-anyof",
  "contracts": [
    {
      "id": "canon-anyof",
      "title": "Canon Any-Of Contract",
      "description": "Accepts scene transition or flag set as narrative progression.",
      "required_flags": [],
      "forbidden_flags": [],
      "required_event_types": [],
      "required_event_types_any_of": [["scene.transition", "flag.set"]],
      "banned_terms": []
    }
  ]
}|};
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"set_flag" ~flag_key:"quest.bridge.secured"
             "The DM marks the bridge as secured.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"explore"
             "I secure the perimeter.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let ok_start, start_body =
    dispatch_exn ctx ~name:"masc_trpg_session_start"
      ~args:
        (`Assoc
          [
            ("session_id", `String "session-canon-anyof");
            ("dm_keeper", `String "dm-keeper");
            ("world_contract_id", `String "canon-anyof");
            ("canon_strict", `Bool true);
            ( "party",
              `List
                [
                  `Assoc
                    [
                      ("actor_id", `String "p1");
                      ("name", `String "Player One");
                      ("keeper_name", `String "pk-1");
                    ];
                ] );
          ])
  in
  Alcotest.(check bool) "session start ok" true ok_start;
  let start_json = parse_json_exn start_body in
  let room_id =
    start_json |> Yojson.Safe.Util.member "room_id" |> Yojson.Safe.Util.to_string
  in
  let player_keepers =
    start_json |> Yojson.Safe.Util.member "round_run_template"
    |> Yojson.Safe.Util.member "player_keepers"
  in
  let ok_round, round_body =
    dispatch_exn ctx ~name:"masc_trpg_round_run"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("dm_keeper", `String "dm-keeper");
            ("player_keepers", player_keepers);
            ("phase", `String "round");
            ("timeout_sec", `Float 1.0);
          ])
  in
  Alcotest.(check bool) "round run ok" true ok_round;
  let round_json = parse_json_exn round_body in
  let canon_check = round_json |> Yojson.Safe.Util.member "canon_check" in
  Alcotest.(check string)
    "canon status pass"
    "pass"
    (canon_check |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check int)
    "any-of missing is empty"
    0
    (canon_check |> Yojson.Safe.Util.member "required_event_types_any_of_missing"
    |> Yojson.Safe.Util.to_list
    |> List.length);
  cleanup_dir base_dir

let test_round_run_emits_combat_semantic_events () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-combat" ~actor_ids:["p1"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Battle lane"
             "The enemy braces.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"attack" ~target_id:"npc-t1-01"
             "I attack the goblin.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-combat");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let summary = parse_json_exn body |> Yojson.Safe.Util.member "summary" in
  let roll_audit_count =
    Yojson.Safe.Util.member "roll_audit_count" summary |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check bool) "roll_audit_count >= 1" true (roll_audit_count >= 1);
  let roll_audit = Yojson.Safe.Util.member "roll_audit" summary |> Yojson.Safe.Util.to_list in
  let first_source =
    roll_audit
    |> List.hd
    |> Yojson.Safe.Util.member "source"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "roll audit source" "combat.attack" first_source;
  let npc_attacks =
    Yojson.Safe.Util.member "npc_attacks" summary |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check bool)
    "auto npc pressure emits npc attack"
    true
    (npc_attacks >= 1);

  let _, stream_attack =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-combat");
            ("event_type", `String "combat.attack");
          ])
  in
  Alcotest.(check bool)
    "combat.attack count includes player + npc pressure"
    true
    (count_from_json (parse_json_exn stream_attack) >= 2);
  let _, stream_dice =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-combat");
            ("event_type", `String "dice.rolled");
          ])
  in
  Alcotest.(check bool)
    "dice.rolled emitted for combat action"
    true
    (count_from_json (parse_json_exn stream_dice) >= 1);
  cleanup_dir base_dir

let test_round_run_reinforces_pressure_after_wave_clear () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let room_id = "room-round-pressure-reinforce" in
  bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:["p1"];
  append_room_event ~base_dir ~room_id
    ~event_type:Trpg.Engine_event.Actor_spawned
    ~payload:
      (`Assoc
        [
          ("turn", `Int 1);
          ("phase", `String "round");
          ("actor_id", `String "npc-seeded");
          ( "actor",
            `Assoc
              [
                ("name", `String "Seeded Threat");
                ("role", `String "npc");
                ("hp", `Int 1);
                ("max_hp", `Int 1);
                ("alive", `Bool true);
                ("traits", `List []);
                ("skills", `List []);
                ("inventory", `List []);
              ] );
        ])
    ();
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Counterpressure"
             "The battlefield does not stay quiet.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"attack" ~target_id:"npc-seeded"
             "I finish the seeded enemy quickly.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String room_id);
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let summary = parse_json_exn body |> Yojson.Safe.Util.member "summary" in
  let npc_spawned =
    Yojson.Safe.Util.member "npc_spawned" summary |> Yojson.Safe.Util.to_int
  in
  let npc_attacks =
    Yojson.Safe.Util.member "npc_attacks" summary |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check bool)
    "pressure reinforcement spawns npc after wave clear"
    true
    (npc_spawned >= 1);
  Alcotest.(check bool)
    "pressure reinforcement still emits npc attack"
    true
    (npc_attacks >= 1);
  cleanup_dir base_dir

let test_round_run_emits_session_outcome_event () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-outcome" ~actor_ids:["p1"];
  let flag_event =
    Trpg.Engine_event.make ~seq:3 ~room_id:"room-round-outcome" ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Flag_set
      ~payload:(`Assoc [ ("scope", `String "world"); ("key", `String "outcome.victory") ])
      ()
  in
  append_event_exn ~base_dir ~event:flag_event;

  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"set_flag" ~flag_key:"outcome.victory"
             "The chapter closes.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"attack" ~target_id:"npc-t1-01"
             "I secure the gate.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-outcome");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let json = parse_json_exn body in
  Alcotest.(check string)
    "outcome payload has victory"
    "victory"
    (json |> Yojson.Safe.Util.member "outcome"
    |> Yojson.Safe.Util.member "outcome"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "room_status ended"
    "ended"
    (json |> Yojson.Safe.Util.member "room_status" |> Yojson.Safe.Util.to_string);

  let _, stream_outcome =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-outcome");
            ("event_type", `String "session.outcome");
          ])
  in
  Alcotest.(check int)
    "session.outcome count"
    1
    (count_from_json (parse_json_exn stream_outcome));
  cleanup_dir base_dir

let test_round_run_uses_current_session_for_outcome_gate () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-restart-outcome" ~actor_ids:["p1"];
  let old_room_end =
    Trpg.Engine_event.make ~seq:3 ~room_id:"room-round-restart-outcome" ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Room_ended
      ~payload:(`Assoc [ ("reason", `String "old_session_done") ])
      ()
  in
  append_event_exn ~base_dir ~event:old_room_end;
  let old_outcome =
    Trpg.Engine_event.make ~seq:4 ~room_id:"room-round-restart-outcome" ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Session_outcome
      ~payload:
        (`Assoc
          [
            ("outcome", `String "victory");
            ("reason", `String "flag:outcome.victory");
            ("summary", `String "Victory condition met.");
            ("turn", `Int 2);
            ("phase", `String "round");
          ])
      ()
  in
  append_event_exn ~base_dir ~event:old_outcome;
  let restarted =
    Trpg.Engine_event.make ~seq:5 ~room_id:"room-round-restart-outcome" ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Room_started
      ~payload:(`Assoc [ ("phase", `String "round") ])
      ()
  in
  append_event_exn ~base_dir ~event:restarted;
  let turn_40 =
    Trpg.Engine_event.make ~seq:6 ~room_id:"room-round-restart-outcome" ~ts:(Types.now_iso ())
      ~event_type:Trpg.Engine_event.Turn_started
      ~payload:(`Assoc [ ("turn", `Int 40) ])
      ()
  in
  append_event_exn ~base_dir ~event:turn_40;

  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"End corridor"
             "The chapter closes.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"attack" ~target_id:"npc-t1-01"
             "I secure the gate.")
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-restart-outcome");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let json = parse_json_exn body in
  Alcotest.(check string)
    "current session reaches draw at max turn"
    "draw"
    (json |> Yojson.Safe.Util.member "outcome"
    |> Yojson.Safe.Util.member "outcome"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "reason is max_turn_reached"
    "max_turn_reached"
    (json |> Yojson.Safe.Util.member "outcome"
    |> Yojson.Safe.Util.member "reason"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "room_status ended"
    "ended"
    (json |> Yojson.Safe.Util.member "room_status" |> Yojson.Safe.Util.to_string);

  let _, stream_outcome =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-restart-outcome");
            ("event_type", `String "session.outcome");
          ])
  in
  Alcotest.(check int)
    "session.outcome includes old + current session"
    2
    (count_from_json (parse_json_exn stream_outcome));

  let _, stream_room_end =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-restart-outcome");
            ("event_type", `String "room.ended");
          ])
  in
  Alcotest.(check int)
    "room.ended includes old + current session"
    2
    (count_from_json (parse_json_exn stream_room_end));
  cleanup_dir base_dir

let test_round_run_timeout_policy () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-timeout" ~actor_ids:["p1"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Arena"
             "Round starts.")
    | "pk-timeout" -> `Timeout
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-timeout");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-timeout") ]);
        ("timeout_sec", `Float 0.2);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success despite timeout" true ok;
  let json = parse_json_exn body in
  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let timeout_status =
    List.find_opt
      (fun s ->
        s |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string = "timeout")
      statuses
  in
  (match timeout_status with
  | Some status_json ->
      Alcotest.(check string)
        "timeout status reason"
        "timeout"
        (status_json |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string)
        "timeout status stage"
        "masc_keeper_msg"
        (status_json |> Yojson.Safe.Util.member "stage" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "timeout status is missing");
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int) "timeouts" 1 (Yojson.Safe.Util.member "timeouts" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "unavailable" 1 (Yojson.Safe.Util.member "unavailable" summary |> Yojson.Safe.Util.to_int);
  (* Player timeout blocks DM execution until full quorum is restored. *)
  Alcotest.(check int) "successes" 0 (Yojson.Safe.Util.member "successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "dm success"
    false
    (Yojson.Safe.Util.member "dm_success" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "round advanced"
    false
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  let dm_status =
    List.find_opt
      (fun s ->
        s |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string = "dm")
      statuses
  in
  (match dm_status with
  | Some status_json ->
      Alcotest.(check string)
        "dm status is skipped"
        "skipped"
        (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dm status is missing");
  let events = json |> Yojson.Safe.Util.member "events" |> Yojson.Safe.Util.to_list in
  let timeout_event =
    List.find_opt
      (fun event_json ->
        event_json |> Yojson.Safe.Util.member "type" |> Yojson.Safe.Util.to_string
        = "turn.timeout")
      events
  in
  (match timeout_event with
  | Some event_json ->
      let payload = event_json |> Yojson.Safe.Util.member "payload" in
      Alcotest.(check string)
        "turn.timeout payload reason"
        "timeout"
        (payload |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string)
        "turn.timeout payload stage"
        "masc_keeper_msg"
        (payload |> Yojson.Safe.Util.member "stage" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "turn.timeout event is missing");
  let unavailable_event =
    List.find_opt
      (fun event_json ->
        event_json |> Yojson.Safe.Util.member "type" |> Yojson.Safe.Util.to_string
        = "keeper.unavailable")
      events
  in
  (match unavailable_event with
  | Some event_json ->
      let payload = event_json |> Yojson.Safe.Util.member "payload" in
      Alcotest.(check string)
        "keeper.unavailable payload reason"
        "timeout"
        (payload |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string)
        "keeper.unavailable payload stage"
        "masc_keeper_msg"
        (payload |> Yojson.Safe.Util.member "stage" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "keeper.unavailable event is missing");

  let _, timeout_stream =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-timeout");
            ("event_type", `String "turn.timeout");
          ])
  in
  Alcotest.(check int)
    "turn.timeout count"
    1
    (count_from_json (parse_json_exn timeout_stream));

  let _, unavailable_stream =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-timeout");
            ("event_type", `String "keeper.unavailable");
          ])
  in
  Alcotest.(check int)
    "keeper.unavailable count"
    1
    (count_from_json (parse_json_exn unavailable_stream));
  cleanup_dir base_dir

let test_round_run_local_fallback_progresses_round () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors
    ~base_dir
    ~room_id:"room-round-local-fallback"
    ~actor_ids:["p1"];
  let keeper_call ~name:_ ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    `Error "keeper runtime unavailable"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    {
      store;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = None;
      dm_voice_emit = None;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-local-fallback");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-down") ]);
        ("timeout_sec", `Float 0.2);
        ("local_fallback", `Bool true);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success via fallback" true ok;

  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "successes exclude fallback"
    0
    (Yojson.Safe.Util.member "successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "player successes exclude fallback"
    0
    (Yojson.Safe.Util.member "player_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "player fallbacks counted"
    1
    (Yojson.Safe.Util.member "player_fallbacks" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "player quorum met with fallback"
    true
    (Yojson.Safe.Util.member "player_quorum_met" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "dm succeeds with fallback"
    true
    (Yojson.Safe.Util.member "dm_success" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "round advances with fallback"
    true
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check int)
    "turn_after advanced"
    2
    (Yojson.Safe.Util.member "turn_after" json |> Yojson.Safe.Util.to_int);

  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let fallback_count =
    List.fold_left
      (fun acc status_json ->
        match status_json |> Yojson.Safe.Util.member "status" with
        | `String "fallback" -> acc + 1
        | _ -> acc)
      0 statuses
  in
  Alcotest.(check int) "fallback statuses" 2 fallback_count;

  let events = json |> Yojson.Safe.Util.member "events" |> Yojson.Safe.Util.to_list in
  let event_types =
    List.filter_map
      (fun event_json ->
        match event_json |> Yojson.Safe.Util.member "type" with
        | `String s -> Some s
        | _ -> None)
      events
  in
  Alcotest.(check bool)
    "actor.spawned emitted"
    true
    (List.mem "actor.spawned" event_types);
  Alcotest.(check bool)
    "combat.attack emitted"
    true
    (List.mem "combat.attack" event_types);
  Alcotest.(check bool)
    "hp.changed emitted"
    true
    (List.mem "hp.changed" event_types);
  Alcotest.(check bool)
    "turn.started emitted"
    true
    (List.mem "turn.started" event_types);
  cleanup_dir base_dir

let test_round_run_local_fallback_distributes_team_pressure () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir
    ~room_id:"room-round-local-fallback-team"
    ~actor_ids:["p1"; "p2"; "p3"; "p4"];
  let keeper_call ~name:_ ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    `Error "keeper runtime unavailable"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    {
      store;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = None;
      dm_voice_emit = None;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-local-fallback-team");
        ("dm_keeper", `String "dm-keeper");
        ( "player_keepers",
          `Assoc
            [
              ("p1", `String "pk-1");
              ("p2", `String "pk-2");
              ("p3", `String "pk-3");
              ("p4", `String "pk-4");
            ] );
        ("timeout_sec", `Float 0.2);
        ("local_fallback", `Bool true);
      ]
  in
  let final_json = ref None in
  for round_idx = 1 to 4 do
    let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
    Alcotest.(check bool)
      (Printf.sprintf "round %d executes" round_idx)
      true ok;
    let json = parse_json_exn body in
    final_json := Some json;
    let turn_before = Yojson.Safe.Util.member "turn_before" json |> Yojson.Safe.Util.to_int in
    let turn_after = Yojson.Safe.Util.member "turn_after" json |> Yojson.Safe.Util.to_int in
    Alcotest.(check int)
      (Printf.sprintf "round %d turn advances" round_idx)
      (turn_before + 1)
      turn_after;
    let has_player_hp_change =
      json |> Yojson.Safe.Util.member "events" |> Yojson.Safe.Util.to_list
      |> List.exists (fun event_json ->
             match
               ( Yojson.Safe.Util.member "type" event_json,
                 Yojson.Safe.Util.member "actor_id" event_json )
             with
             | `String "hp.changed", `String actor_id ->
                 String.length actor_id > 0 && actor_id.[0] = 'p'
             | _ -> false)
    in
    Alcotest.(check bool)
      (Printf.sprintf "round %d emits player hp pressure" round_idx)
      true has_player_hp_change
  done;
  let json =
    match !final_json with
    | Some json -> json
    | None -> failwith "expected final json after fallback loop"
  in
  let hp_of actor_id =
    json |> Yojson.Safe.Util.member "state" |> Yojson.Safe.Util.member "party"
    |> Yojson.Safe.Util.member actor_id |> Yojson.Safe.Util.member "hp"
    |> Yojson.Safe.Util.to_int
  in
  let damaged_players =
    [ "p1"; "p2"; "p3"; "p4" ]
    |> List.filter (fun actor_id -> hp_of actor_id < 1000)
  in
  Alcotest.(check bool)
    "team pressure is distributed across multiple players"
    true
    (List.length damaged_players >= 2);
  let dm_fallback_reply =
    json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list
    |> List.find_map (fun status_json ->
           match
             ( Yojson.Safe.Util.member "actor_id" status_json,
               Yojson.Safe.Util.member "status" status_json,
               Yojson.Safe.Util.member "reply" status_json )
           with
           | `String "dm", `String "fallback", `String reply -> Some reply
           | _ -> None)
    |> Option.value ~default:""
  in
  Alcotest.(check bool)
    "dm fallback avoids placeholder text"
    false
    (contains_substring dm_fallback_reply "상황을 살피며 다음 행동을 준비합니다");
  cleanup_dir base_dir

let test_round_run_unavailable_sampling_cap () =
  Eio_main.run @@ fun _env ->
  with_env "MASC_TRPG_KEEPER_UNAVAILABLE_MAX_PER_TURN" "1" (fun () ->
    let base_dir = make_temp_dir () in
    let config = Room.default_config base_dir in
    let _ = Room.init config ~agent_name:(Some "tester") in
    bootstrap_room_with_actors ~base_dir ~room_id:"room-round-unavailable-sampled"
      ~actor_ids:["p1"];
    let seeded_unavailable =
      Trpg.Engine_event.make ~seq:3 ~room_id:"room-round-unavailable-sampled"
        ~ts:(Types.now_iso ()) ~event_type:Trpg.Engine_event.Keeper_unavailable
        ~actor_id:"p1"
        ~payload:
          (`Assoc
            [
              ("phase", `String "round");
              ("turn", `Int 1);
              ("role", `String "player");
              ("actor_id", `String "p1");
              ("keeper", `String "pk-timeout");
              ("reason", `String "timeout");
              ("stage", `String "masc_keeper_msg");
            ])
        ()
    in
    append_event_exn ~base_dir ~event:seeded_unavailable;
    let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
      match name with
      | "dm-keeper" ->
          `Ok
            (keeper_payload ~action_type:"scene_transition" ~scene:"Round starts"
               "Round starts.")
      | "pk-timeout" -> `Timeout
      | _ -> `Error "unknown keeper"
    in
    let store = Trpg.Store.make_sqlite ~base_dir in
    let ctx : Tool_trpg.context =
      { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
    in
    let args =
      `Assoc
        [
          ("room_id", `String "room-round-unavailable-sampled");
          ("dm_keeper", `String "dm-keeper");
          ("player_keepers", `Assoc [ ("p1", `String "pk-timeout") ]);
          ("timeout_sec", `Float 0.2);
        ]
    in
    let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
    Alcotest.(check bool) "round_run success despite sampling" true ok;
    let json = parse_json_exn body in
    let summary = Yojson.Safe.Util.member "summary" json in
    Alcotest.(check int)
      "timeouts remain tracked"
      1
      (Yojson.Safe.Util.member "timeouts" summary |> Yojson.Safe.Util.to_int);
    Alcotest.(check int)
      "unavailable summary counts appended events only"
      0
      (Yojson.Safe.Util.member "unavailable" summary |> Yojson.Safe.Util.to_int);
    let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
    let timeout_status =
      List.find_opt
        (fun s ->
          s |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string = "timeout")
        statuses
    in
    (match timeout_status with
    | Some status_json ->
        Alcotest.(check bool)
          "timeout unavailable sampled"
          true
          (status_json |> Yojson.Safe.Util.member "sampled" |> Yojson.Safe.Util.to_bool);
        Alcotest.(check string)
          "sampled reason duplicate"
          "duplicate"
          (status_json |> Yojson.Safe.Util.member "sampled_reason" |> Yojson.Safe.Util.to_string)
    | None -> Alcotest.fail "timeout status is missing");
    let _, unavailable_stream =
      dispatch_exn ctx ~name:"masc_trpg_stream"
        ~args:
          (`Assoc
            [
              ("room_id", `String "room-round-unavailable-sampled");
              ("event_type", `String "keeper.unavailable");
            ])
    in
    Alcotest.(check int)
      "keeper.unavailable count unchanged"
      1
      (count_from_json (parse_json_exn unavailable_stream));
    cleanup_dir base_dir)

let test_round_run_uses_majority_player_quorum () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors
    ~base_dir
    ~room_id:"room-round-quorum"
    ~actor_ids:["p1"; "p2"];
  let dm_called = ref false in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        dm_called := true;
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Partial quorum"
             "DM still responds with partial quorum.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"explore" "I move to flank.")
    | "pk-timeout" -> `Timeout
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-quorum");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1"); ("p2", `String "pk-timeout") ]);
        ("timeout_sec", `Float 0.2);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run returns payload" true ok;
  Alcotest.(check bool) "dm call executes on quorum success" true !dm_called;

  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "player_successes"
    1
    (Yojson.Safe.Util.member "player_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "player_required_successes"
    1
    (Yojson.Safe.Util.member "player_required_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "player quorum met"
    true
    (Yojson.Safe.Util.member "player_quorum_met" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "dm success"
    true
    (Yojson.Safe.Util.member "dm_success" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "round advanced"
    true
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check int)
    "turn_after advanced"
    2
    (Yojson.Safe.Util.member "turn_after" json |> Yojson.Safe.Util.to_int);

  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let dm_status =
    List.find_opt
      (fun s ->
        s |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string = "dm")
      statuses
  in
  (match dm_status with
  | Some status_json ->
      Alcotest.(check string)
        "dm status is ok"
        "ok"
        (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dm status is missing");
  cleanup_dir base_dir

let test_round_run_skips_dead_player_assignments () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let room_id = "room-round-dead-assignment" in
  bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:["p1"; "p2"];
  let dead_keeper_called = ref false in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Aftermath"
             "The round advances with surviving actors.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"attack" ~target_id:"npc-t1-01"
             "I strike the nearest threat.")
    | "pk-dead" ->
        dead_keeper_called := true;
        `Ok (keeper_payload ~action_type:"explore" "This should never run.")
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let ok_update, _ =
    dispatch_exn ctx ~name:"masc_trpg_actor_update"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "p2");
            ("hp", `Int 0);
            ("alive", `Bool false);
          ])
  in
  Alcotest.(check bool) "mark p2 dead" true ok_update;
  let args =
    `Assoc
      [
        ("room_id", `String room_id);
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1"); ("p2", `String "pk-dead") ]);
        ("timeout_sec", `Float 0.5);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run returns payload" true ok;
  Alcotest.(check bool) "dead keeper should not be called" false !dead_keeper_called;
  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "player_successes from alive actors only"
    1
    (Yojson.Safe.Util.member "player_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "player_required_successes from alive actors only"
    1
    (Yojson.Safe.Util.member "player_required_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "player quorum met"
    true
    (Yojson.Safe.Util.member "player_quorum_met" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "round advanced"
    true
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let dead_status =
    List.find_opt
      (fun s ->
        s |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string = "p2")
      statuses
  in
  (match dead_status with
  | Some status_json ->
      Alcotest.(check string)
        "dead actor status marked skipped_dead"
        "skipped_dead"
        (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dead actor status is missing");
  cleanup_dir base_dir

let test_round_run_short_circuits_when_session_already_ended () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let room_id = "room-round-session-ended" in
  bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:["p1"];
  append_room_event ~base_dir ~room_id
    ~event_type:Trpg.Engine_event.Session_outcome
    ~payload:
      (`Assoc
        [
          ("outcome", `String "defeat");
          ("reason", `String "all_players_dead");
          ("summary", `String "The party has fallen.");
          ("turn", `Int 1);
          ("phase", `String "round");
        ])
    ();
  let keeper_called = ref false in
  let keeper_call ~name:_ ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    keeper_called := true;
    `Ok (keeper_payload ~action_type:"explore" "Should not be called.")
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String room_id);
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("timeout_sec", `Float 0.5);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run returns payload" true ok;
  Alcotest.(check bool) "keeper call skipped on ended session" false !keeper_called;
  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check string)
    "progress reason is session_ended"
    "session_ended"
    (Yojson.Safe.Util.member "progress_reason" summary |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "round not advanced"
    false
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check int)
    "no emitted events"
    0
    (Yojson.Safe.Util.member "events" json |> Yojson.Safe.Util.to_list |> List.length);
  let statuses = Yojson.Safe.Util.member "statuses" json |> Yojson.Safe.Util.to_list in
  let dm_status =
    List.find_opt
      (fun s ->
        s |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string = "dm")
      statuses
  in
  (match dm_status with
  | Some status_json ->
      Alcotest.(check string)
        "dm status is skipped_session_ended"
        "skipped_session_ended"
        (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dm status is missing");
  cleanup_dir base_dir

let test_round_run_rejects_meta_only_keeper_reply () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-meta-reply" ~actor_ids:["p1"];
  let dm_called = ref false in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        dm_called := true;
        `Ok (`Assoc [ ("reply", `String "DM should be skipped.") ])
    | "pk-meta" -> `Ok (`Assoc [ ("reply", `String "[/STATE]") ])
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-meta-reply");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-meta") ]);
        ("timeout_sec", `Float 0.2);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run returns payload" true ok;
  Alcotest.(check bool)
    "dm call proceeds after synthetic recovery for meta-only player reply"
    true
    !dm_called;

  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "player_successes"
    1
    (Yojson.Safe.Util.member "player_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "reprompts"
    0
    (Yojson.Safe.Util.member "reprompts" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "player quorum met"
    true
    (Yojson.Safe.Util.member "player_quorum_met" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "round advanced"
    true
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);

  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let p1_status =
    List.find_opt
      (fun s ->
        match
          ( Yojson.Safe.Util.member "actor_id" s,
            Yojson.Safe.Util.member "status" s )
        with
        | `String "p1", `String "inferred_pre_reprompt" -> true
        | _ -> false)
      statuses
  in
  (match p1_status with
  | Some status_json ->
      Alcotest.(check string)
        "p1 status is inferred_pre_reprompt"
        "inferred_pre_reprompt"
        (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string)
        "p1 reason is synthetic"
        "keeper_reply_synthesized"
        (status_json |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "p1 inferred_pre_reprompt status is missing");
  cleanup_dir base_dir

let test_round_run_requires_keeper_runtime () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-no-keeper");
        ("dm_keeper", `String "dm");
        ("player_keepers", `Assoc [ ("p1", `String "k1") ]);
      ]
  in
  let ok, msg = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "fails without keeper runtime" false ok;
  Alcotest.(check bool)
    "error message includes keeper_call"
    true
    (contains_substring msg "keeper_call is not available");
  cleanup_dir base_dir

let test_round_run_preflight_warning_is_non_blocking () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors
    ~base_dir
    ~room_id:"room-round-preflight"
    ~actor_ids:["p1"];
  let keeper_called = ref false in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    keeper_called := true;
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Warning flow"
             "execution proceeds with warning")
    | _ ->
        `Ok
          (keeper_payload ~action_type:"explore"
             "execution proceeds with warning")
  in
  let keeper_probe ~name : Tool_trpg.keeper_probe_result =
    match name with
    | "dm-keeper" -> `Ok
    | "pk-down" -> `Error "keeper not found"
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    {
      store;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = Some keeper_probe;
      dm_voice_emit = None;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-preflight");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-down") ]);
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run continues despite preflight warning" true ok;
  Alcotest.(check bool) "keeper_call executes even with preflight warning" true !keeper_called;
  let json = parse_json_exn body in
  let preflight_warning =
    json |> Yojson.Safe.Util.member "preflight_warning" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool)
    "warning includes preflight marker"
    true
    (contains_substring preflight_warning "keeper preflight failed");
  Alcotest.(check bool)
    "warning includes failing keeper"
    true
    (contains_substring preflight_warning "pk-down=");
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "successes"
    2
    (Yojson.Safe.Util.member "successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "round advanced"
    true
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  cleanup_dir base_dir

let test_round_run_lang_english_prompt () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-lang-en" ~actor_ids:["p1"];
  let prompts = ref [] in
  let keeper_call ~name ~message ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    prompts := (name, message) :: !prompts;
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Bridge"
             "Scene starts.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"defend" "I move to cover.")
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-lang-en");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("lang", `String "en");
      ]
  in
  let ok, _body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success (lang=en)" true ok;
  let has_en_instruction =
    List.exists
      (fun (_name, prompt) -> contains_substring prompt "Respond in English.")
      !prompts
  in
  Alcotest.(check bool) "english prompt instruction injected" true has_en_instruction;
  cleanup_dir base_dir

let test_round_run_dm_prompt_reflects_player_action () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors
    ~base_dir
    ~room_id:"room-round-dm-context"
    ~actor_ids:["p1"];
  let prompts = ref [] in
  let keeper_call ~name ~message ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    prompts := (name, message) :: !prompts;
    match name with
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"explore" "왼쪽 엄폐물 뒤로 이동해 정찰한다.")
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"정찰 후 전진"
             "정찰 결과를 받아 다음 장면을 연다.")
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-dm-context");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
      ]
  in
  let ok, _body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let dm_prompt =
    !prompts
    |> List.find_opt (fun (name, _) -> name = "dm-keeper")
    |> Option.map snd
    |> Option.value ~default:""
  in
  Alcotest.(check bool)
    "dm prompt includes latest player action"
    true
    (contains_substring dm_prompt "왼쪽 엄폐물 뒤로 이동해 정찰한다.");
  cleanup_dir base_dir

let test_round_run_rejects_non_unique_keepers () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name:_ ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    `Ok (keeper_payload ~action_type:"scene_transition" ~scene:"noop" "noop")
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-dup-keepers");
        ("dm_keeper", `String "shared-keeper");
        ( "player_keepers",
          `Assoc
            [
              ("p1", `String "pk-1");
              ("p2", `String "shared-keeper");
            ] );
      ]
  in
  let ok, msg = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run should fail on non-unique keepers" false ok;
  Alcotest.(check bool)
    "error mentions unique keeper assignment"
    true
    (contains_substring msg "must be unique");
  cleanup_dir base_dir

let test_session_bootstrap_and_intervention_flow () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result
      =
    if name = "dm-keeper" then
      `Ok
        (keeper_payload ~action_type:"scene_transition" ~scene:"grim plot"
           "The DM advances the grim plot.")
    else if String.starts_with ~prefix:"pk-" name then
      `Ok
        (keeper_payload ~action_type:"investigate"
           "Player executes assigned tactic.")
    else
      `Error ("unknown keeper: " ^ name)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let session_id = "session-bootstrap-1" in
  let ok_preset, preset_body =
    dispatch_exn ctx ~name:"masc_trpg_preset_list" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "preset list ok" true ok_preset;
  Alcotest.(check bool) "preset list has dm presets" true
    ((parse_json_exn preset_body |> Yojson.Safe.Util.member "dm_presets" |> Yojson.Safe.Util.to_list |> List.length) >= 1);

  let ok_pool, pool_body =
    dispatch_exn ctx ~name:"masc_trpg_pool_generate"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("pool_size", `Int 6);
            ("party_size", `Int 4);
            ("seed", `Int 7);
          ])
  in
  Alcotest.(check bool) "pool generate ok" true ok_pool;
  let pool_json = parse_json_exn pool_body in
  let pool = pool_json |> Yojson.Safe.Util.member "pool" |> Yojson.Safe.Util.to_list in
  let suggested =
    pool_json |> Yojson.Safe.Util.member "suggested_party_ids"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check int) "pool size" 6 (List.length pool);
  Alcotest.(check int) "suggested party size" 4 (List.length suggested);

  let ok_party, party_body =
    dispatch_exn ctx ~name:"masc_trpg_party_select"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("pool", `List pool);
            ("selected_player_ids", `List suggested);
          ])
  in
  Alcotest.(check bool) "party select ok" true ok_party;
  let party_json = parse_json_exn party_body in
  let party = party_json |> Yojson.Safe.Util.member "party" |> Yojson.Safe.Util.to_list in
  Alcotest.(check int) "party size" 4 (List.length party);

  let ok_start, start_body =
    dispatch_exn ctx ~name:"masc_trpg_session_start"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("party", `List party);
          ])
  in
  Alcotest.(check bool) "session start ok" true ok_start;
  let start_json = parse_json_exn start_body in
  let room_id =
    start_json |> Yojson.Safe.Util.member "room_id" |> Yojson.Safe.Util.to_string
  in
  let round_template =
    start_json
    |> Yojson.Safe.Util.member "round_run_template"
    |> Yojson.Safe.Util.member "player_keepers"
  in

  let ok_intrv, intrv_body =
    dispatch_exn ctx ~name:"masc_trpg_intervention_submit"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("session_id", `String session_id);
            ("intervention_type", `String "nudge");
            ("payload", `Assoc [ ("target", `String "trust"); ("delta", `Float 0.1) ]);
          ])
  in
  Alcotest.(check bool) "intervention submit ok" true ok_intrv;
  let intrv_json = parse_json_exn intrv_body in
  Alcotest.(check string) "intervention status" "pending"
    (intrv_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);

  let ok_round, round_body =
    dispatch_exn ctx ~name:"masc_trpg_round_run"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("dm_keeper", `String "dm-keeper");
            ("player_keepers", round_template);
            ("phase", `String "round");
            ("timeout_sec", `Float 0.5);
          ])
  in
  Alcotest.(check bool) "round run ok" true ok_round;
  let round_json = parse_json_exn round_body in
  let summary = round_json |> Yojson.Safe.Util.member "summary" in
  Alcotest.(check int) "interventions applied count" 1
    (summary |> Yojson.Safe.Util.member "interventions" |> Yojson.Safe.Util.to_int);

  let _, stream_applied =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("event_type", `String "intervention.applied");
          ])
  in
  Alcotest.(check int) "intervention.applied event count" 1
    (count_from_json (parse_json_exn stream_applied));
  cleanup_dir base_dir

let test_examples_scenario_visible_as_world_preset () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let scenario_dir = Filename.concat config.base_path "examples/trpg-mvp/scenarios" in
  ensure_dir scenario_dir;
  write_file
    (Filename.concat scenario_dir "grimland-prologue-v1.json")
    {|{
  "id": "grimland-prologue-v1",
  "title": "그림란드 연대기: 여관의 첫 밤",
  "type": "narrative",
  "description": "비가 멈추지 않는 밤, 여관에서 시작되는 연대기.",
  "acts": [
    { "id": "act-1", "title": "첫 번째 종", "description": "낯선 자들이 하나씩 문을 연다." }
  ],
  "runtime": { "max_rounds": 6 }
}|};
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in

  let ok_preset, preset_body =
    dispatch_exn ctx ~name:"masc_trpg_preset_list" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "preset list ok" true ok_preset;
  let world_ids =
    parse_json_exn preset_body
    |> Yojson.Safe.Util.member "world_presets"
    |> Yojson.Safe.Util.to_list
    |> List.map (fun j -> j |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string)
  in
  Alcotest.(check bool) "scenario id included in world presets" true
    (List.mem "grimland-prologue-v1" world_ids);

  let ok_start, start_body =
    dispatch_exn ctx ~name:"masc_trpg_session_start"
      ~args:
        (`Assoc
          [
            ("session_id", `String "session-scenario-bridge");
            ("world_preset_id", `String "grimland-prologue-v1");
          ])
  in
  Alcotest.(check bool) "session start ok with scenario world_preset_id" true ok_start;
  let start_json = parse_json_exn start_body in
  Alcotest.(check string)
    "session uses scenario preset id"
    "grimland-prologue-v1"
    (start_json |> Yojson.Safe.Util.member "world_preset"
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check int)
    "scenario runtime max_rounds reflected in end_rules.max_turn"
    6
    (start_json |> Yojson.Safe.Util.member "world_preset"
    |> Yojson.Safe.Util.member "end_rules"
    |> Yojson.Safe.Util.member "max_turn"
    |> Yojson.Safe.Util.to_int);
  cleanup_dir base_dir

let test_actor_spawn_claim_release_flow () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let room_id = "room-actor-lease-flow" in

  let ok_spawn1, _spawn1 =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-raven");
            ("role", `String "npc");
            ("name", `String "Raven");
            ("skills", `List [ `String "scout" ]);
          ])
  in
  Alcotest.(check bool) "spawn actor1 ok" true ok_spawn1;

  let ok_claim1, _claim1 =
    dispatch_exn ctx ~name:"masc_trpg_actor_claim"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-raven");
            ("keeper_name", `String "keeper-raven");
          ])
  in
  Alcotest.(check bool) "claim actor1 ok" true ok_claim1;

  let ok_claim_same, claim_same_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_claim"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-raven");
            ("keeper_name", `String "keeper-raven");
          ])
  in
  Alcotest.(check bool) "idempotent same-keeper claim ok" true ok_claim_same;
  Alcotest.(check string)
    "same claim returns already_claimed"
    "already_claimed"
    (parse_json_exn claim_same_body |> Yojson.Safe.Util.member "status"
   |> Yojson.Safe.Util.to_string);

  let ok_spawn2, _spawn2 =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-owl");
            ("role", `String "npc");
          ])
  in
  Alcotest.(check bool) "spawn actor2 ok" true ok_spawn2;

  let ok_claim2_conflict, claim2_conflict_msg =
    dispatch_exn ctx ~name:"masc_trpg_actor_claim"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-owl");
            ("keeper_name", `String "keeper-raven");
          ])
  in
  Alcotest.(check bool) "keeper cannot control two actors" false ok_claim2_conflict;
  Alcotest.(check bool)
    "error mentions keeper already controls actor"
    true
    (contains_substring claim2_conflict_msg "keeper already controls actor");

  let ok_release_wrong, release_wrong_msg =
    dispatch_exn ctx ~name:"masc_trpg_actor_release"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-raven");
            ("keeper_name", `String "keeper-wrong");
          ])
  in
  Alcotest.(check bool) "release by non-owner fails" false ok_release_wrong;
  Alcotest.(check bool)
    "release error mentions another keeper"
    true
    (contains_substring release_wrong_msg "another keeper");

  let ok_release, _release_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_release"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-raven");
            ("keeper_name", `String "keeper-raven");
          ])
  in
  Alcotest.(check bool) "release by owner ok" true ok_release;

  let ok_claim2, _claim2 =
    dispatch_exn ctx ~name:"masc_trpg_actor_claim"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-owl");
            ("keeper_name", `String "keeper-raven");
          ])
  in
  Alcotest.(check bool) "claim actor2 after release ok" true ok_claim2;

  let _, stream_claimed =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("event_type", `String "actor.claimed");
          ])
  in
  Alcotest.(check int)
    "actor.claimed count"
    2
    (count_from_json (parse_json_exn stream_claimed));

  let _, stream_released =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("event_type", `String "actor.released");
          ])
  in
  Alcotest.(check int)
    "actor.released count"
    1
    (count_from_json (parse_json_exn stream_released));
  cleanup_dir base_dir

let test_actor_spawn_auto_generates_actor_id () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let room_id = "room-actor-auto-id" in

  let ok_spawn1, spawn1_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("name", `String "Night Fox");
            ("role", `String "npc");
          ])
  in
  Alcotest.(check bool) "auto spawn 1 ok" true ok_spawn1;
  let spawn1_json = parse_json_exn spawn1_body in
  let actor_id1 = spawn1_json |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "auto actor_id from name" "night-fox" actor_id1;
  Alcotest.(check bool) "state contains actor_id1" true
    ((spawn1_json |> Yojson.Safe.Util.member "state" |> Yojson.Safe.Util.member "party"
    |> Yojson.Safe.Util.member actor_id1)
    <> `Null);

  let ok_spawn2, spawn2_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("name", `String "Night Fox");
            ("role", `String "npc");
          ])
  in
  Alcotest.(check bool) "auto spawn 2 ok" true ok_spawn2;
  let actor_id2 =
    parse_json_exn spawn2_body |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "collision adds suffix" "night-fox-2" actor_id2;

  let ok_spawn3, spawn3_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:(`Assoc [ ("room_id", `String room_id) ])
  in
  Alcotest.(check bool) "auto spawn 3 with defaults ok" true ok_spawn3;
  let actor_id3 =
    parse_json_exn spawn3_body |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "default role seed is player" "player" actor_id3;
  cleanup_dir base_dir

let test_actor_spawn_profile_fields () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let room_id = "room-actor-profile-fields" in
  let actor_id = "pc-luna" in

  let ok_spawn, spawn_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("name", `String "Luna");
            ("portrait", `String "https://example.com/luna.png");
            ("background", `String "폐허 수색 전문가");
            ( "stats",
              `Assoc
                [ ("str", `Int 10); ("dex", `Int 16); ("wis", `Int 14); ("luck", `Int 7) ] );
          ])
  in
  Alcotest.(check bool) "spawn profile fields ok" true ok_spawn;
  let spawn_json = parse_json_exn spawn_body in
  let actor_state =
    spawn_json |> Yojson.Safe.Util.member "state" |> Yojson.Safe.Util.member "party"
    |> Yojson.Safe.Util.member actor_id
  in
  Alcotest.(check string)
    "portrait preserved"
    "https://example.com/luna.png"
    (actor_state |> Yojson.Safe.Util.member "portrait" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "background preserved"
    "폐허 수색 전문가"
    (actor_state |> Yojson.Safe.Util.member "background" |> Yojson.Safe.Util.to_string);
  Alcotest.(check int)
    "stats.dex preserved"
    16
    (actor_state |> Yojson.Safe.Util.member "stats" |> Yojson.Safe.Util.member "dex"
   |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "stats.luck preserved"
    7
    (actor_state |> Yojson.Safe.Util.member "stats" |> Yojson.Safe.Util.member "luck"
   |> Yojson.Safe.Util.to_int);

  let ok_update, update_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_update"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("background", `String "폭풍 마법 학파 출신");
            ("stats", `Assoc [ ("str", `Int 11); ("int", `Int 15); ("luck", `Int 9) ]);
          ])
  in
  Alcotest.(check bool) "update profile fields ok" true ok_update;
  let actor_state_after =
    parse_json_exn update_body |> Yojson.Safe.Util.member "state" |> Yojson.Safe.Util.member "party"
    |> Yojson.Safe.Util.member actor_id
  in
  Alcotest.(check string)
    "background updated"
    "폭풍 마법 학파 출신"
    (actor_state_after |> Yojson.Safe.Util.member "background" |> Yojson.Safe.Util.to_string);
  Alcotest.(check int)
    "stats.int updated"
    15
    (actor_state_after |> Yojson.Safe.Util.member "stats" |> Yojson.Safe.Util.member "int"
   |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "stats.luck updated"
    9
    (actor_state_after |> Yojson.Safe.Util.member "stats" |> Yojson.Safe.Util.member "luck"
   |> Yojson.Safe.Util.to_int);
  cleanup_dir base_dir

let test_actor_update_delete_flow () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let room_id = "room-actor-update-delete" in
  let actor_id = "npc-fox" in

  let ok_spawn, _spawn =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("role", `String "npc");
            ("name", `String "Fox");
            ("hp", `Int 10);
            ("max_hp", `Int 10);
            ("traits", `List [ `String "sneaky" ]);
          ])
  in
  Alcotest.(check bool) "spawn actor ok" true ok_spawn;

  let ok_claim, _claim =
    dispatch_exn ctx ~name:"masc_trpg_actor_claim"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("keeper_name", `String "keeper-fox");
          ])
  in
  Alcotest.(check bool) "claim actor ok" true ok_claim;

  let ok_update, update_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_update"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("name", `String "Fox Prime");
            ("hp", `Int 0);
            ("max_hp", `Int 12);
            ("alive", `Bool false);
            ("traits", `List [ `String "swift"; `String "cunning" ]);
            ("skills", `List [ `String "dash" ]);
            ("inventory", `List [ `String "potion" ]);
          ])
  in
  Alcotest.(check bool) "update actor ok" true ok_update;
  let update_json = parse_json_exn update_body in
  let state = Yojson.Safe.Util.member "state" update_json in
  let actor = state |> Yojson.Safe.Util.member "party" |> Yojson.Safe.Util.member actor_id in
  Alcotest.(check string) "updated name" "Fox Prime"
    (actor |> Yojson.Safe.Util.member "name" |> Yojson.Safe.Util.to_string);
  Alcotest.(check int) "updated hp" 0
    (actor |> Yojson.Safe.Util.member "hp" |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "updated max_hp" 12
    (actor |> Yojson.Safe.Util.member "max_hp" |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool) "updated alive false" false
    (actor |> Yojson.Safe.Util.member "alive" |> Yojson.Safe.Util.to_bool);
  Alcotest.(check int) "inventory size" 1
    (actor |> Yojson.Safe.Util.member "inventory" |> Yojson.Safe.Util.to_list |> List.length);
  Alcotest.(check bool) "actor lease released when dead" true
    ((state |> Yojson.Safe.Util.member "actor_control" |> Yojson.Safe.Util.member actor_id) = `Null);

  let ok_delete, delete_body =
    dispatch_exn ctx ~name:"masc_trpg_actor_delete"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String actor_id);
            ("reason", `String "retired");
          ])
  in
  Alcotest.(check bool) "delete actor ok" true ok_delete;
  let delete_state =
    parse_json_exn delete_body |> Yojson.Safe.Util.member "state"
  in
  Alcotest.(check bool) "actor removed from party" true
    ((delete_state |> Yojson.Safe.Util.member "party" |> Yojson.Safe.Util.member actor_id)
    = `Null);

  let _, stream_updated =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("event_type", `String "actor.updated");
          ])
  in
  Alcotest.(check int)
    "actor.updated count"
    1
    (count_from_json (parse_json_exn stream_updated));

  let _, stream_deleted =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("event_type", `String "actor.deleted");
          ])
  in
  Alcotest.(check int)
    "actor.deleted count"
    1
    (count_from_json (parse_json_exn stream_deleted));
  cleanup_dir base_dir

let test_actor_claim_rejects_dead_actor () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let room_id = "room-actor-dead-claim" in
  let ok_spawn, _spawn =
    dispatch_exn ctx ~name:"masc_trpg_actor_spawn"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-fallen");
            ("role", `String "npc");
            ("hp", `Int 0);
            ("max_hp", `Int 10);
            ("alive", `Bool false);
          ])
  in
  Alcotest.(check bool) "spawn dead actor ok" true ok_spawn;

  let ok_claim, claim_msg =
    dispatch_exn ctx ~name:"masc_trpg_actor_claim"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "npc-fallen");
            ("keeper_name", `String "keeper-fallen");
          ])
  in
  Alcotest.(check bool) "claim dead actor fails" false ok_claim;
  Alcotest.(check bool)
    "error mentions not alive"
    true
    (contains_substring claim_msg "not alive");
  cleanup_dir base_dir

let test_mid_join_eligibility_and_request_flow () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let room_id = "room-mid-join-flow" in
  bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:[ "p1" ];
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in

  let ok0, body0 =
    dispatch_exn ctx ~name:"masc_trpg_join_eligibility"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "p1");
            ("keeper_name", `String "keeper-p1");
          ])
  in
  Alcotest.(check bool) "eligibility call ok" true ok0;
  let json0 = parse_json_exn body0 in
  Alcotest.(check bool) "not eligible initially" false
    (json0 |> Yojson.Safe.Util.member "eligible" |> Yojson.Safe.Util.to_bool);

  append_room_event ~base_dir ~room_id
    ~event_type:Trpg.Engine_event.Turn_action_resolved
    ~actor_id:"p1"
    ~payload:(`Assoc [ ("actor_id", `String "p1"); ("result", `String "advance") ])
    ();
  append_room_event ~base_dir ~room_id
    ~event_type:Trpg.Engine_event.Dice_rolled
    ~actor_id:"p1"
    ~payload:
      (`Assoc
        [
          ("actor_id", `String "p1");
          ("action", `String "ability_check");
          ("passed", `Bool true);
          ("total", `Int 14);
        ])
    ();

  let ok1, body1 =
    dispatch_exn ctx ~name:"masc_trpg_join_eligibility"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "p1");
            ("keeper_name", `String "keeper-p1");
          ])
  in
  Alcotest.(check bool) "eligibility call ok after score" true ok1;
  let json1 = parse_json_exn body1 in
  Alcotest.(check bool) "eligible after score" true
    (json1 |> Yojson.Safe.Util.member "eligible" |> Yojson.Safe.Util.to_bool);

  let ok_join, join_body =
    dispatch_exn ctx ~name:"masc_trpg_mid_join_request"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "p1");
            ("keeper_name", `String "keeper-p1");
          ])
  in
  Alcotest.(check bool) "mid join request ok" true ok_join;
  let join_json = parse_json_exn join_body in
  Alcotest.(check bool) "mid join granted" true
    (join_json |> Yojson.Safe.Util.member "granted" |> Yojson.Safe.Util.to_bool);
  let state = join_json |> Yojson.Safe.Util.member "state" in
  let actor = state |> Yojson.Safe.Util.member "party" |> Yojson.Safe.Util.member "p1" in
  Alcotest.(check int) "late_join_penalty_turns starts at 2" 2
    (actor |> Yojson.Safe.Util.member "late_join_penalty_turns" |> Yojson.Safe.Util.to_int);

  let ok_adv1, adv_body1 =
    dispatch_exn ctx ~name:"masc_trpg_turn_advance"
      ~args:(`Assoc [ ("room_id", `String room_id) ])
  in
  Alcotest.(check bool) "turn advance1 ok" true ok_adv1;
  let state1 = parse_json_exn adv_body1 |> Yojson.Safe.Util.member "state" in
  Alcotest.(check int) "late_join_penalty_turns decremented to 1" 1
    (state1 |> Yojson.Safe.Util.member "party" |> Yojson.Safe.Util.member "p1"
    |> Yojson.Safe.Util.member "late_join_penalty_turns"
    |> Yojson.Safe.Util.to_int);

  let ok_adv2, adv_body2 =
    dispatch_exn ctx ~name:"masc_trpg_turn_advance"
      ~args:(`Assoc [ ("room_id", `String room_id) ])
  in
  Alcotest.(check bool) "turn advance2 ok" true ok_adv2;
  let state2 = parse_json_exn adv_body2 |> Yojson.Safe.Util.member "state" in
  Alcotest.(check int) "late_join_penalty_turns decremented to 0" 0
    (state2 |> Yojson.Safe.Util.member "party" |> Yojson.Safe.Util.member "p1"
    |> Yojson.Safe.Util.member "late_join_penalty_turns"
    |> Yojson.Safe.Util.to_int);
  cleanup_dir base_dir

let test_mid_join_reject_when_window_closed () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let room_id = "room-mid-join-closed" in
  bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:[ "p2" ];
  append_room_event ~base_dir ~room_id
    ~event_type:Trpg.Engine_event.Join_window_closed
    ~payload:(`Assoc [ ("turn", `Int 1); ("reason", `String "test") ])
    ();
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
  in
  let ok_join, join_body =
    dispatch_exn ctx ~name:"masc_trpg_mid_join_request"
      ~args:
        (`Assoc
          [
            ("room_id", `String room_id);
            ("actor_id", `String "p2");
            ("keeper_name", `String "keeper-p2");
          ])
  in
  Alcotest.(check bool) "mid join request processed" true ok_join;
  let join_json = parse_json_exn join_body in
  Alcotest.(check bool) "mid join rejected" false
    (join_json |> Yojson.Safe.Util.member "granted" |> Yojson.Safe.Util.to_bool);
  Alcotest.(check string) "reason code is window closed" "join_window_closed"
    (join_json |> Yojson.Safe.Util.member "reason_code" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

(* ================================================================
   entropy_seed / pick_by_seed unit tests
   ================================================================ *)

let test_entropy_seed_different_sessions () =
  let s1 = Tool_trpg.entropy_seed ~session_id:"sess-aaa" ~salt:"round" in
  let s2 = Tool_trpg.entropy_seed ~session_id:"sess-bbb" ~salt:"round" in
  Alcotest.(check bool)
    "different session IDs produce different seeds"
    true (s1 <> s2)

let test_entropy_seed_different_salts () =
  let s1 = Tool_trpg.entropy_seed ~session_id:"sess-x" ~salt:"dm" in
  let s2 = Tool_trpg.entropy_seed ~session_id:"sess-x" ~salt:"world" in
  Alcotest.(check bool)
    "different salts produce different seeds"
    true (s1 <> s2)

let test_entropy_seed_returns_int () =
  let s = Tool_trpg.entropy_seed ~session_id:"test" ~salt:"salt" in
  (* Just verify it returns a valid int by checking it's representable *)
  Alcotest.(check bool) "seed is an integer" true (s = s)

let test_pick_by_seed_empty_list () =
  let result = Tool_trpg.pick_by_seed ~seed:42 [] in
  Alcotest.(check (option string)) "empty list returns None" None result

let test_pick_by_seed_single_element () =
  let result = Tool_trpg.pick_by_seed ~seed:0 ["only"] in
  Alcotest.(check (option string)) "single element always returned" (Some "only") result;
  let result2 = Tool_trpg.pick_by_seed ~seed:999 ["only"] in
  Alcotest.(check (option string)) "single element with any seed" (Some "only") result2

let test_pick_by_seed_returns_valid_element () =
  let items = ["alpha"; "beta"; "gamma"; "delta"] in
  let result = Tool_trpg.pick_by_seed ~seed:7 items in
  match result with
  | None -> Alcotest.fail "expected Some but got None"
  | Some v ->
    Alcotest.(check bool)
      "returned element is in the original list"
      true (List.mem v items)

let test_pick_by_seed_deterministic () =
  let items = ["a"; "b"; "c"; "d"; "e"] in
  let r1 = Tool_trpg.pick_by_seed ~seed:42 items in
  let r2 = Tool_trpg.pick_by_seed ~seed:42 items in
  Alcotest.(check (option string)) "same seed same result" r1 r2

let test_pick_by_seed_negative_seed () =
  let items = ["x"; "y"; "z"] in
  let result = Tool_trpg.pick_by_seed ~seed:(-5) items in
  match result with
  | None -> Alcotest.fail "expected Some but got None for negative seed"
  | Some v ->
    Alcotest.(check bool)
      "negative seed still returns valid element"
      true (List.mem v items)

(* --- Phase E: structured_action + stagnation tests --- *)

let test_extract_structured_action_attack () =
  let json =
    `Assoc
      [
        ("reply", `String "I strike the goblin with my sword.");
        ( "structured_action",
          `Assoc
            [
              ("type", `String "attack");
              ("target_id", `String "npc-goblin-01");
              ("description", `String "Sword swing at goblin");
            ] );
      ]
  in
  match Tool_trpg.extract_structured_action json with
  | None -> Alcotest.fail "expected Some structured_action for attack"
  | Some sa ->
      Alcotest.(check string)
        "action type is attack"
        "attack"
        (Tool_trpg.string_of_action_type sa.sa_type);
      Alcotest.(check (option string))
        "target_id extracted"
        (Some "npc-goblin-01")
        sa.target_id;
      Alcotest.(check string)
        "description extracted"
        "Sword swing at goblin"
        sa.description

let test_extract_structured_action_set_flag () =
  let json =
    `Assoc
      [
        ("reply", `String "The party discovers the hidden entrance.");
        ( "structured_action",
          `Assoc
            [
              ("type", `String "set_flag");
              ("flag_key", `String "quest.hideout.found");
              ("description", `String "Hidden entrance discovered");
            ] );
      ]
  in
  match Tool_trpg.extract_structured_action json with
  | None -> Alcotest.fail "expected Some structured_action for set_flag"
  | Some sa ->
      Alcotest.(check string)
        "action type is set_flag"
        "set_flag"
        (Tool_trpg.string_of_action_type sa.sa_type);
      Alcotest.(check (option string))
        "flag_key extracted"
        (Some "quest.hideout.found")
        sa.flag_key

let test_extract_structured_action_invalid () =
  let json_no_sa = `Assoc [ ("reply", `String "I look around.") ] in
  Alcotest.(check bool)
    "None when no structured_action field"
    true
    (Tool_trpg.extract_structured_action json_no_sa = None);
  let json_bad_type =
    `Assoc
      [
        ( "structured_action",
          `Assoc
            [
              ("type", `String "foobar_unknown");
              ("description", `String "something");
            ] );
      ]
  in
  Alcotest.(check bool)
    "None when unknown action type"
    true
    (Tool_trpg.extract_structured_action json_bad_type = None);
  let json_empty_sa = `Assoc [ ("structured_action", `Assoc []) ] in
  Alcotest.(check bool)
    "None when structured_action is empty object"
    true
    (Tool_trpg.extract_structured_action json_empty_sa = None)

let test_apply_structured_action_emits_flag_set () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let room_id = "room-sa-flag" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let _ = Room.init (Room.default_config base_dir) ~agent_name:(Some "tester") in
      bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:[ "p1" ];
      let store = Trpg.Store.make_sqlite ~base_dir in
      let sa : Tool_trpg.structured_action =
        {
          sa_type = Tool_trpg.SetFlag;
          target_id = None;
          description = "Victory flag set by DM";
          flag_key = Some "outcome.victory";
          scene = None;
          quest_info = None;
          memory_hint = None;
          raw_payload = `Assoc [];
        }
      in
      match
        Tool_trpg.apply_structured_action ~store ~room_id ~turn:1
          ~phase:"round" ~actor_id:"dm" ~state:(`Assoc []) sa
      with
      | Error e -> Alcotest.fail ("apply_structured_action failed: " ^ e)
      | Ok events ->
          let has_flag_set =
            List.exists
              (fun (ev : Trpg.Engine_event.t) ->
                ev.event_type = Trpg.Engine_event.Flag_set)
              events
          in
          Alcotest.(check bool) "Flag_set event emitted" true has_flag_set;
          let flag_event =
            List.find
              (fun (ev : Trpg.Engine_event.t) ->
                ev.event_type = Trpg.Engine_event.Flag_set)
              events
          in
          let key =
            flag_event.payload |> Yojson.Safe.Util.member "key"
            |> Yojson.Safe.Util.to_string
          in
          Alcotest.(check string) "flag key is outcome.victory" "outcome.victory" key)

let test_apply_structured_action_emits_scene_transition () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let room_id = "room-sa-scene" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let _ = Room.init (Room.default_config base_dir) ~agent_name:(Some "tester") in
      bootstrap_room_with_actors ~base_dir ~room_id ~actor_ids:[ "p1" ];
      let store = Trpg.Store.make_sqlite ~base_dir in
      let sa : Tool_trpg.structured_action =
        {
          sa_type = Tool_trpg.SceneTransition;
          target_id = None;
          description = "The party enters the dark cave";
          flag_key = None;
          scene = Some "The Dark Cave";
          quest_info = None;
          memory_hint = None;
          raw_payload = `Assoc [];
        }
      in
      match
        Tool_trpg.apply_structured_action ~store ~room_id ~turn:2
          ~phase:"round" ~actor_id:"dm" ~state:(`Assoc []) sa
      with
      | Error e -> Alcotest.fail ("apply_structured_action failed: " ^ e)
      | Ok events ->
          let has_scene =
            List.exists
              (fun (ev : Trpg.Engine_event.t) ->
                ev.event_type = Trpg.Engine_event.Scene_transition)
              events
          in
          Alcotest.(check bool) "Scene_transition event emitted" true has_scene;
          let scene_event =
            List.find
              (fun (ev : Trpg.Engine_event.t) ->
                ev.event_type = Trpg.Engine_event.Scene_transition)
              events
          in
          let scene_name =
            scene_event.payload |> Yojson.Safe.Util.member "scene"
            |> Yojson.Safe.Util.to_string
          in
          Alcotest.(check string) "scene is The Dark Cave" "The Dark Cave" scene_name)

let make_event ~seq ~room_id ~event_type =
  Trpg.Engine_event.make ~seq ~room_id ~ts:(Types.now_iso ()) ~event_type
    ~payload:(`Assoc []) ()

let test_detect_stagnation_true () =
  let room_id = "room-stagnation" in
  let events =
    [
      make_event ~seq:1 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:2 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:3 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:4 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:5 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:6 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:7 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:8 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:9 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:10 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
    ]
  in
  Alcotest.(check bool)
    "5 empty turns -> stagnation detected"
    true
    (Tool_trpg.detect_stagnation ~events ~threshold:5)

let test_detect_stagnation_false () =
  let room_id = "room-no-stagnation" in
  let events =
    [
      make_event ~seq:1 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:2 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:3 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:4 ~room_id ~event_type:Trpg.Engine_event.Flag_set;
      make_event ~seq:5 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:6 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:7 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:8 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
      make_event ~seq:9 ~room_id ~event_type:Trpg.Engine_event.Turn_started;
      make_event ~seq:10 ~room_id ~event_type:Trpg.Engine_event.Narration_posted;
    ]
  in
  Alcotest.(check bool)
    "Flag_set in window -> no stagnation"
    false
    (Tool_trpg.detect_stagnation ~events ~threshold:5)

let test_fallback_tracked_separately () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-fallback-track"
    ~actor_ids:[ "p1"; "p2" ];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Fallback lane"
             "The scene continues...")
    | _ -> `Timeout
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    {
      store;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = None;
      dm_voice_emit = None;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-fallback-track");
        ("local_fallback", `Bool true);
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1"); ("p2", `String "pk-2") ]);
      ]
  in
  let _ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  let json = parse_json_exn body in
  let summary = json |> Yojson.Safe.Util.member "summary" in
  let fallbacks =
    summary |> Yojson.Safe.Util.member "fallbacks" |> Yojson.Safe.Util.to_int
  in
  let successes =
    summary |> Yojson.Safe.Util.member "successes" |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check bool)
    "fallback_count > 0 (players timed out)"
    true (fallbacks > 0);
  Alcotest.(check bool)
    "successes still counts fallbacks for quorum"
    true (successes > 0);
  cleanup_dir base_dir

let test_end_to_end_victory_via_flags () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-victory-flag"
    ~actor_ids:[ "p1" ];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (`Assoc
            [
              ("reply", `String "The heroes triumph over evil.");
              ( "structured_action",
                `Assoc
                  [
                    ("type", `String "set_flag");
                    ("flag_key", `String "outcome.victory");
                    ("description", `String "Heroes win the final battle");
                  ] );
            ])
    | "pk-1" ->
        `Ok
          (`Assoc
            [
              ("reply", `String "I deliver the final blow.");
              ( "structured_action",
                `Assoc
                  [
                    ("type", `String "attack");
                    ("target_id", `String "npc-boss");
                    ("description", `String "Final strike");
                  ] );
            ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    {
      store;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = None;
      dm_voice_emit = None;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-victory-flag");
        ("local_fallback", `Bool true);
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers",
         `Assoc [ ("p1", `String "pk-1") ]);
      ]
  in
  let _ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  let json = parse_json_exn body in
  let outcome_obj = json |> Yojson.Safe.Util.member "outcome" in
  let outcome_str =
    outcome_obj |> Yojson.Safe.Util.member "outcome"
    |> Yojson.Safe.Util.to_string_option
  in
  let outcome_reason =
    outcome_obj |> Yojson.Safe.Util.member "reason"
    |> Yojson.Safe.Util.to_string_option
  in
  Alcotest.(check (option string))
    "outcome is Victory"
    (Some "victory") outcome_str;
  Alcotest.(check bool)
    "outcome_reason mentions flag"
    true
    (match outcome_reason with
    | Some r -> contains_substring r "flag:"
    | None -> false);
  cleanup_dir base_dir

let test_round_run_reprompts_once_for_missing_structured_action () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-reprompt-once"
    ~actor_ids:["p1"];
  let p1_calls = ref 0 in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Reprompt test"
             "The scene shifts after the player's action.")
    | "pk-1" ->
        p1_calls := !p1_calls + 1;
        if !p1_calls = 1 then
          `Ok (`Assoc [ ("reply", `String "I hesitate for a moment.") ])
        else
          `Ok
            (`Assoc
              [
                ( "reply",
                  `String
                    "I dash forward.\nstructured_action: {\"type\":\"attack\",\"target_id\":\"npc-t1-01\",\"description\":\"I dash forward.\"}" );
              ])
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-reprompt-once");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("lang", `String "en");
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  Alcotest.(check int)
    "player keeper called once due pre-reprompt inference recovery"
    1
    !p1_calls;
  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "reprompts"
    0
    (Yojson.Safe.Util.member "reprompts" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int)
    "schema_failures remain zero when pre-reprompt inference recovers"
    0
    (Yojson.Safe.Util.member "schema_failures" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "advanced after reprompt recovery"
    true
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);
  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let inferred_status =
    List.exists
      (fun status_json ->
        match
          ( Yojson.Safe.Util.member "actor_id" status_json,
            Yojson.Safe.Util.member "status" status_json )
        with
        | `String "p1", `String "inferred_pre_reprompt" -> true
        | _ -> false)
      statuses
  in
  Alcotest.(check bool)
    "status includes inferred_pre_reprompt marker"
    true
    inferred_status;
  cleanup_dir base_dir

let test_round_run_dm_persona_override_in_prompt_and_summary () =
  Eio_main.run @@ fun _env ->
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-persona-override"
    ~actor_ids:["p1"];
  let prompts = ref [] in
  let keeper_call ~name ~message ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    prompts := (name, message) :: !prompts;
    match name with
    | "dm-keeper" ->
        `Ok
          (keeper_payload ~action_type:"scene_transition" ~scene:"Persona chamber"
             "The tactical layout sharpens.")
    | "pk-1" ->
        `Ok
          (keeper_payload ~action_type:"investigate" "I inspect enemy positions.")
    | _ -> `Error "unknown keeper"
  in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_trpg.context =
    { store; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-persona-override");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("lang", `String "en");
        ("dm_persona", `String "tactical_irony");
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let dm_prompt =
    !prompts
    |> List.find_opt (fun (name, _) -> name = "dm-keeper")
    |> Option.map snd
    |> Option.value ~default:""
  in
  Alcotest.(check bool)
    "dm prompt contains tactical irony persona directive"
    true
    (contains_substring dm_prompt "Persona: Tactical Irony.");
  let summary = parse_json_exn body |> Yojson.Safe.Util.member "summary" in
  Alcotest.(check string)
    "summary includes overridden dm persona"
    "tactical_irony"
    (Yojson.Safe.Util.member "dm_persona" summary |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "summary marks override as true"
    true
    (Yojson.Safe.Util.member "dm_persona_overridden" summary |> Yojson.Safe.Util.to_bool);
  cleanup_dir base_dir

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run "Tool_trpg coverage"
    [
      ( "preset",
        [
          Alcotest.test_case
            "examples scenario is mapped as world preset"
            `Quick
            test_examples_scenario_visible_as_world_preset;
        ] );
      ( "session",
        [
          Alcotest.test_case
            "bootstrap + intervention + round"
            `Quick
            test_session_bootstrap_and_intervention_flow;
        ] );
      ( "round_run",
        [
          Alcotest.test_case
            "success path"
            `Quick
            test_round_run_success_path;
          Alcotest.test_case
            "memory hint guardrail escalates tier"
            `Quick
            test_round_run_memory_hint_guardrail_escalates_tier;
          Alcotest.test_case
            "canon strict check can fail while returning payload"
            `Quick
            test_round_run_canon_check_strict_failure;
          Alcotest.test_case
            "canon any-of event rule passes with flag.set"
            `Quick
            test_round_run_canon_any_of_passes_with_flag_set;
          Alcotest.test_case
            "timeout policy emits events"
            `Quick
            test_round_run_timeout_policy;
          Alcotest.test_case
            "local fallback progresses round and emits combat events"
            `Quick
            test_round_run_local_fallback_progresses_round;
          Alcotest.test_case
            "local fallback distributes pressure across multi-player team"
            `Quick
            test_round_run_local_fallback_distributes_team_pressure;
          Alcotest.test_case
            "samples keeper.unavailable when cap reached"
            `Quick
            test_round_run_unavailable_sampling_cap;
          Alcotest.test_case
            "uses majority player quorum before dm/advance"
            `Quick
            test_round_run_uses_majority_player_quorum;
          Alcotest.test_case
            "skips dead player assignments and keeps round progression"
            `Quick
            test_round_run_skips_dead_player_assignments;
          Alcotest.test_case
            "short-circuits when session is already ended"
            `Quick
            test_round_run_short_circuits_when_session_already_ended;
          Alcotest.test_case
            "recovers meta-only keeper replies via synthetic action"
            `Quick
            test_round_run_rejects_meta_only_keeper_reply;
          Alcotest.test_case
            "requires keeper runtime"
            `Quick
            test_round_run_requires_keeper_runtime;
          Alcotest.test_case
            "preflight warning is non-blocking"
            `Quick
            test_round_run_preflight_warning_is_non_blocking;
          Alcotest.test_case
            "supports lang=en prompt"
            `Quick
            test_round_run_lang_english_prompt;
          Alcotest.test_case
            "pre-reprompt inference recovers missing structured_action in one keeper call"
            `Quick
            test_round_run_reprompts_once_for_missing_structured_action;
          Alcotest.test_case
            "applies dm persona override in prompt and summary"
            `Quick
            test_round_run_dm_persona_override_in_prompt_and_summary;
          Alcotest.test_case
            "dm prompt reflects player action"
            `Quick
            test_round_run_dm_prompt_reflects_player_action;
          Alcotest.test_case
            "emits combat semantic events"
            `Quick
            test_round_run_emits_combat_semantic_events;
          Alcotest.test_case
            "reinforces npc pressure after wave clear"
            `Quick
            test_round_run_reinforces_pressure_after_wave_clear;
          Alcotest.test_case
            "emits session outcome event"
            `Quick
            test_round_run_emits_session_outcome_event;
          Alcotest.test_case
            "current session outcome gate ignores past session outcome"
            `Quick
            test_round_run_uses_current_session_for_outcome_gate;
          Alcotest.test_case
            "rejects non-unique keepers"
            `Quick
            test_round_run_rejects_non_unique_keepers;
        ] );
      ( "actor_control",
        [
          Alcotest.test_case
            "spawn + claim + release flow"
            `Quick
            test_actor_spawn_claim_release_flow;
          Alcotest.test_case
            "auto actor_id generation on spawn"
            `Quick
            test_actor_spawn_auto_generates_actor_id;
          Alcotest.test_case
            "spawn/update profile fields"
            `Quick
            test_actor_spawn_profile_fields;
          Alcotest.test_case
            "update + delete flow"
            `Quick
            test_actor_update_delete_flow;
          Alcotest.test_case
            "reject dead actor claim"
            `Quick
            test_actor_claim_rejects_dead_actor;
          Alcotest.test_case
            "mid join eligibility + request + penalty decay"
            `Quick
            test_mid_join_eligibility_and_request_flow;
          Alcotest.test_case
            "mid join rejects when join window is closed"
            `Quick
            test_mid_join_reject_when_window_closed;
        ] );
      ( "entropy",
        [
          Alcotest.test_case
            "different sessions produce different seeds"
            `Quick
            test_entropy_seed_different_sessions;
          Alcotest.test_case
            "different salts produce different seeds"
            `Quick
            test_entropy_seed_different_salts;
          Alcotest.test_case
            "entropy_seed returns an int"
            `Quick
            test_entropy_seed_returns_int;
          Alcotest.test_case
            "pick_by_seed empty list returns None"
            `Quick
            test_pick_by_seed_empty_list;
          Alcotest.test_case
            "pick_by_seed single element always returned"
            `Quick
            test_pick_by_seed_single_element;
          Alcotest.test_case
            "pick_by_seed returns valid element from list"
            `Quick
            test_pick_by_seed_returns_valid_element;
          Alcotest.test_case
            "pick_by_seed is deterministic"
            `Quick
            test_pick_by_seed_deterministic;
          Alcotest.test_case
            "pick_by_seed handles negative seed"
            `Quick
            test_pick_by_seed_negative_seed;
        ] );
      ( "structured_action",
        [
          Alcotest.test_case "extract attack" `Quick
            test_extract_structured_action_attack;
          Alcotest.test_case "extract set_flag" `Quick
            test_extract_structured_action_set_flag;
          Alcotest.test_case "extract invalid returns None" `Quick
            test_extract_structured_action_invalid;
          Alcotest.test_case "apply emits Flag_set" `Quick
            test_apply_structured_action_emits_flag_set;
          Alcotest.test_case "apply emits Scene_transition" `Quick
            test_apply_structured_action_emits_scene_transition;
          Alcotest.test_case "system instructions constant is non-empty" `Quick
            (fun () ->
              let s = Tool_trpg.trpg_structured_action_system_instructions in
              Alcotest.(check bool)
                "instructions non-empty"
                true
                (String.length s > 100);
              Alcotest.(check bool)
                "mentions structured_action"
                true
                (String.trim s |> fun s ->
                 try
                   let _ = Str.search_forward (Str.regexp_string "structured_action") s 0 in
                   true
                 with Not_found -> false));
        ] );
      ( "stagnation_and_fallback",
        [
          Alcotest.test_case "stagnation detected after empty turns" `Quick
            test_detect_stagnation_true;
          Alcotest.test_case "no stagnation with meaningful events" `Quick
            test_detect_stagnation_false;
          Alcotest.test_case "fallback tracked separately" `Quick
            test_fallback_tracked_separately;
          Alcotest.test_case "victory via flags E2E" `Quick
            test_end_to_end_victory_via_flags;
        ] );
    ]
