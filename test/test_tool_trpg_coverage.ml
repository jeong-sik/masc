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

let dispatch_exn ctx ~name ~args =
  match Tool_trpg.dispatch ctx ~name ~args with
  | Some r -> r
  | None -> failwith ("dispatch returned None for " ^ name)

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let count_from_json json = json |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int

let test_round_run_success_path () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "The scene opens in rain.") ])
    | "pk-1" -> `Ok (`Assoc [ ("reply", `String "I scout ahead.") ])
    | "pk-2" -> `Ok (`Assoc [ ("reply", `String "I hold defensive line.") ])
    | other -> `Error ("unknown keeper: " ^ other)
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call }
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

let test_round_run_timeout_policy () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let keeper_call ~name ~message:_ ~timeout_sec:_ : Tool_trpg.keeper_call_result =
    match name with
    | "dm-keeper" -> `Ok (`Assoc [ ("reply", `String "Round starts.") ])
    | "pk-timeout" -> `Timeout
    | _ -> `Error "unknown keeper"
  in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = Some keeper_call }
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
  let summary = Yojson.Safe.Util.member "summary" json in
  Alcotest.(check int) "timeouts" 1 (Yojson.Safe.Util.member "timeouts" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "unavailable" 1 (Yojson.Safe.Util.member "unavailable" summary |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "successes" 1 (Yojson.Safe.Util.member "successes" summary |> Yojson.Safe.Util.to_int);

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

let test_round_run_requires_keeper_runtime () =
  let base_dir = make_temp_dir () in
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let ctx : Tool_trpg.context =
    { config; agent_name = "tester"; keeper_call = None }
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
    { config; agent_name = "tester"; keeper_call = Some keeper_call }
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

let () =
  Alcotest.run "Tool_trpg coverage"
    [
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
            "requires keeper runtime"
            `Quick
            test_round_run_requires_keeper_runtime;
        ] );
    ]
