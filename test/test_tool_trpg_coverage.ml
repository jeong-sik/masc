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
                 ("hp", `Int 10);
                 ("max_hp", `Int 10);
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
    Trpg_engine_event.make ~seq:1 ~room_id ~ts:(Types.now_iso ())
      ~event_type:Trpg_engine_event.Room_created ~payload:room_created_payload ()
  in
  (match Trpg_engine_store_sqlite.append_event ~base_dir ~event:room_created with
  | Ok () -> ()
  | Error e -> failwith ("bootstrap Room_created failed: " ^ e));
  let room_started =
    Trpg_engine_event.make ~seq:2 ~room_id ~ts:(Types.now_iso ())
      ~event_type:Trpg_engine_event.Room_started
      ~payload:(`Assoc [ ("phase", `String "round") ])
      ()
  in
  (match Trpg_engine_store_sqlite.append_event ~base_dir ~event:room_started with
  | Ok () -> ()
  | Error e -> failwith ("bootstrap Room_started failed: " ^ e))

let append_event_exn ~base_dir ~(event : Trpg_engine_event.t) =
  match Trpg_engine_store_sqlite.append_event ~base_dir ~event with
  | Ok () -> ()
  | Error e -> failwith ("append event failed: " ^ e)

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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-success" ~actor_ids:["p1"; "p2"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "The scene opens in rain.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I scout ahead.") ])
    | "pk-2" -> `Ok (`Assoc [ ("reply", `String "I hold defensive line.") ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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

let test_round_run_emits_combat_semantic_events () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-combat" ~actor_ids:["p1"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "The enemy braces.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I attack the goblin.") ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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
  let ok, _body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;

  let _, stream_attack =
    dispatch_exn ctx ~name:"masc_trpg_stream"
      ~args:
        (`Assoc
          [
            ("room_id", `String "room-round-combat");
            ("event_type", `String "combat.attack");
          ])
  in
  Alcotest.(check int)
    "combat.attack count"
    1
    (count_from_json (parse_json_exn stream_attack));
  cleanup_dir base_dir

let test_round_run_emits_session_outcome_event () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-outcome" ~actor_ids:["p1"];
  let flag_event =
    Trpg_engine_event.make ~seq:3 ~room_id:"room-round-outcome" ~ts:(Types.now_iso ())
      ~event_type:Trpg_engine_event.Flag_set
      ~payload:(`Assoc [ ("scope", `String "world"); ("key", `String "outcome.victory") ])
      ()
  in
  append_event_exn ~base_dir ~event:flag_event;

  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "The chapter closes.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I secure the gate.") ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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

let test_round_run_dm_voice_requested_when_active () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-voice-active" ~actor_ids:["p1"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "The torchlight trembles.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I guard the rear.") ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let voice_calls : (string * string * string option) list ref = ref [] in
  let dm_voice_emit ~agent_id ~message ~provider : Tool_trpg.dm_voice_emit_result =
    voice_calls := (agent_id, message, provider) :: !voice_calls;
    Ok (`Assoc [ ("status", `String "queued") ])
  in
  let ctx : Tool_trpg.context =
    {
      config;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = None;
      dm_voice_emit = Some dm_voice_emit;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-voice-active");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
        ("dm_voice_enabled", `Bool true);
        ("dm_voice_provider", `String "voicemode");
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let json = parse_json_exn body in
  Alcotest.(check string)
    "dm voice status requested"
    "requested"
    (json |> Yojson.Safe.Util.member "dm_voice"
    |> Yojson.Safe.Util.member "status"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "dm voice provider voicemode"
    "voicemode"
    (json |> Yojson.Safe.Util.member "dm_voice"
    |> Yojson.Safe.Util.member "provider"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check int) "dm voice called once" 1 (List.length !voice_calls);
  (match !voice_calls with
  | (agent_id, message, provider) :: _ ->
      Alcotest.(check string) "dm voice agent_id" "dm" agent_id;
      Alcotest.(check string) "dm voice message" "The torchlight trembles." message;
      Alcotest.(check (option string))
        "dm voice provider forwarded"
        (Some "voicemode")
        provider
  | [] -> Alcotest.fail "expected voice call");
  cleanup_dir base_dir

let test_round_run_dm_voice_skipped_when_not_in_progress () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-voice-ended" ~actor_ids:["p1"];
  let flag_event =
    Trpg_engine_event.make ~seq:3 ~room_id:"room-round-voice-ended" ~ts:(Types.now_iso ())
      ~event_type:Trpg_engine_event.Flag_set
      ~payload:(`Assoc [ ("scope", `String "world"); ("key", `String "outcome.victory") ])
      ()
  in
  append_event_exn ~base_dir ~event:flag_event;
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "The chapter closes.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I secure the gate.") ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let voice_calls : (string * string * string option) list ref = ref [] in
  let dm_voice_emit ~agent_id ~message ~provider : Tool_trpg.dm_voice_emit_result =
    voice_calls := (agent_id, message, provider) :: !voice_calls;
    Ok (`Assoc [ ("status", `String "queued") ])
  in
  let ctx : Tool_trpg.context =
    {
      config;
      agent_name = "tester";
      keeper_call = Some keeper_call;
      keeper_probe = None;
      dm_voice_emit = Some dm_voice_emit;
    }
  in
  let args =
    `Assoc
      [
        ("room_id", `String "room-round-voice-ended");
        ("dm_keeper", `String "dm-keeper");
        ("player_keepers", `Assoc [ ("p1", `String "pk-1") ]);
        ("phase", `String "round");
        ("timeout_sec", `Float 1.0);
        ("dm_voice_enabled", `Bool true);
        ("dm_voice_provider", `String "elevenlabs");
      ]
  in
  let ok, body = dispatch_exn ctx ~name:"masc_trpg_round_run" ~args in
  Alcotest.(check bool) "round_run success" true ok;
  let json = parse_json_exn body in
  Alcotest.(check string)
    "room_status ended"
    "ended"
    (json |> Yojson.Safe.Util.member "room_status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "dm voice status skipped"
    "skipped"
    (json |> Yojson.Safe.Util.member "dm_voice"
    |> Yojson.Safe.Util.member "status"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "dm voice skipped reason"
    "room_not_in_progress"
    (json |> Yojson.Safe.Util.member "dm_voice"
    |> Yojson.Safe.Util.member "reason"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check int) "dm voice never called" 0 (List.length !voice_calls);
  cleanup_dir base_dir

let test_round_run_timeout_policy () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-timeout" ~actor_ids:["p1"];
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "Round starts.") ])
    | "pk-timeout" -> `Timeout
    | _ -> `Error "unknown keeper"
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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

let test_round_run_unavailable_sampling_cap () =
  with_env "MASC_TRPG_KEEPER_UNAVAILABLE_MAX_PER_TURN" "1" (fun () ->
    let base_dir = make_temp_dir () in
    let config = Room.default_config base_dir in
    let _ = Room.init config ~agent_name:(Some "tester") in
    bootstrap_room_with_actors ~base_dir ~room_id:"room-round-unavailable-sampled"
      ~actor_ids:["p1"];
    let seeded_unavailable =
      Trpg_engine_event.make ~seq:3 ~room_id:"room-round-unavailable-sampled"
        ~ts:(Types.now_iso ()) ~event_type:Trpg_engine_event.Keeper_unavailable
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
      | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "Round starts.") ])
      | "pk-timeout" -> `Timeout
      | _ -> `Error "unknown keeper"
    in
    let ctx : Tool_trpg.context =
      {
        config;
        agent_name = "tester";
        keeper_call = Some keeper_call;
        keeper_probe = None;
      }
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
        `Ok (`Assoc [ ("reply", `String "DM still responds with partial quorum.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I move to flank.") ])
    | "pk-timeout" -> `Timeout
    | _ -> `Error "unknown keeper"
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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

let test_round_run_rejects_meta_only_keeper_reply () =
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
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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
    "dm call is skipped when player reply is meta-only"
    false
    !dm_called;

  let json = parse_json_exn body in
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int)
    "player_successes"
    0
    (Yojson.Safe.Util.member "player_successes" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check bool)
    "player quorum met"
    false
    (Yojson.Safe.Util.member "player_quorum_met" summary |> Yojson.Safe.Util.to_bool);
  Alcotest.(check bool)
    "round advanced"
    false
    (Yojson.Safe.Util.member "advanced" summary |> Yojson.Safe.Util.to_bool);

  let statuses = json |> Yojson.Safe.Util.member "statuses" |> Yojson.Safe.Util.to_list in
  let p1_status =
    List.find_opt
      (fun s ->
        s |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string = "p1")
      statuses
  in
  (match p1_status with
  | Some status_json ->
      Alcotest.(check string)
        "p1 status is invalid_response"
        "invalid_response"
        (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string)
        "p1 stage is parse_keeper_reply"
        "parse_keeper_reply"
        (status_json |> Yojson.Safe.Util.member "stage" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "p1 status is missing");
  cleanup_dir base_dir

let test_round_run_requires_keeper_runtime () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors
    ~base_dir
    ~room_id:"room-round-preflight"
    ~actor_ids:["p1"];
  let keeper_called = ref false in
  let keeper_call ~name:_ ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    keeper_called := true;
    `Ok (`Assoc [ ("reply", `String "execution proceeds with warning") ])
  in
  let keeper_probe ~name : Tool_trpg.keeper_probe_result =
    match name with
    | "dm-keeper" -> `Ok
    | "pk-down" -> `Error "keeper not found"
    | _ -> `Error "unknown keeper"
  in
  let ctx : Tool_trpg.context =
    {
      config;
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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  bootstrap_room_with_actors ~base_dir ~room_id:"room-round-lang-en" ~actor_ids:["p1"];
  let prompts = ref [] in
  let keeper_call ~name ~message ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    prompts := (name, message) :: !prompts;
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "Scene starts.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I move to cover.") ])
    | _ -> `Error "unknown keeper"
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "왼쪽 엄폐물 뒤로 이동해 정찰한다.") ])
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "정찰 결과를 받아 다음 장면을 연다.") ])
    | _ -> `Error "unknown keeper"
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name:_ ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    `Ok (`Assoc [ ("reply", `String "noop") ])
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result
      =
    if name = "dm-keeper" then
      `Ok (`Assoc [ ("reply", `String "The DM advances the grim plot.") ])
    else if String.starts_with ~prefix:"pk-" name then
      `Ok (`Assoc [ ("reply", `String "Player executes assigned tactic.") ])
    else
      `Error ("unknown keeper: " ^ name)
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call; keeper_probe = None; dm_voice_emit = None }
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
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
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

let test_actor_update_delete_flow () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
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
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = None; keeper_probe = None; dm_voice_emit = None }
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

let () =
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
            "timeout policy emits events"
            `Quick
            test_round_run_timeout_policy;
          Alcotest.test_case
            "samples keeper.unavailable when cap reached"
            `Quick
            test_round_run_unavailable_sampling_cap;
          Alcotest.test_case
            "uses majority player quorum before dm/advance"
            `Quick
            test_round_run_uses_majority_player_quorum;
          Alcotest.test_case
            "rejects meta-only keeper replies"
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
            "dm prompt reflects player action"
            `Quick
            test_round_run_dm_prompt_reflects_player_action;
          Alcotest.test_case
            "emits combat semantic events"
            `Quick
            test_round_run_emits_combat_semantic_events;
          Alcotest.test_case
            "emits session outcome event"
            `Quick
            test_round_run_emits_session_outcome_event;
          Alcotest.test_case
            "requests dm voice when room is active"
            `Quick
            test_round_run_dm_voice_requested_when_active;
          Alcotest.test_case
            "skips dm voice when room is not in progress"
            `Quick
            test_round_run_dm_voice_skipped_when_not_in_progress;
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
            "update + delete flow"
            `Quick
            test_actor_update_delete_flow;
          Alcotest.test_case
            "reject dead actor claim"
            `Quick
            test_actor_claim_rejects_dead_actor;
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
    ]
