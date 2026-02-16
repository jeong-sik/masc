open Alcotest
open Yojson.Safe.Util
open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_protocol_game_view_" "" in
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

let mk_ctx base_dir =
  let config = Room.default_config base_dir in
  let _ = Room.init config ~agent_name:(Some "tester") in
  let ctx : Tool_protocol_game_view.context =
    { config; agent_name = "tester"; trpg_keeper_call = None }
  in
  (config, ctx)

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> fail ("invalid json: " ^ e)

let dispatch_exn ctx ~name ~args =
  match Tool_protocol_game_view.dispatch ctx ~name ~args with
  | Some r -> r
  | None -> fail ("dispatch returned None for " ^ name)

let extract_decision_id body =
  body |> parse_json |> member "payload" |> member "decision_id" |> to_string

let finalize_for_session ctx ~session_id =
  let create_args =
    `Assoc
      [
        ("session_id", `String session_id);
        ("issue", `String "pick route");
        ("options", `List [ `String "A"; `String "B" ]);
      ]
  in
  let ok_create, out_create =
    dispatch_exn ctx ~name:"decision.create" ~args:create_args
  in
  check bool "decision.create ok" true ok_create;
  let decision_id = extract_decision_id out_create in
  let finalize_args =
    `Assoc
      [
        ("session_id", `String session_id);
        ("decision_id", `String decision_id);
        ("selected_option", `String "A");
        ("rationale", `String "best option");
        ("verifier", `String "PASS");
      ]
  in
  let ok_finalize, out_finalize =
    dispatch_exn ctx ~name:"decision.finalize" ~args:finalize_args
  in
  check bool "decision.finalize ok" true ok_finalize;
  check string "decision.finalize status" "finalized"
    (out_finalize |> parse_json |> member "payload" |> member "status" |> to_string)

let test_precondition_required_without_finalize () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let args =
        `Assoc
          [ ("session_id", `String "sess-precond"); ("hypothesis", `String "h") ]
      in
      let ok, body = dispatch_exn ctx ~name:"experiment.start" ~args in
      check bool "experiment.start should fail before finalize" false ok;
      let json = parse_json body in
      check string "error code"
        "PRECONDITION_REQUIRED"
        (json |> member "payload" |> member "code" |> to_string))

let test_decision_then_experiment_start () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      finalize_for_session ctx ~session_id:"sess-exp-ok";
      let args =
        `Assoc
          [
            ("session_id", `String "sess-exp-ok");
            ("hypothesis", `String "engagement grows");
            ("metrics", `List [ `String "engagement" ]);
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"experiment.start" ~args in
      check bool "experiment.start ok" true ok;
      let status =
        body |> parse_json |> member "payload" |> member "status" |> to_string
      in
      check string "experiment status" "running" status)

let test_legacy_alias_experiment_start_passthrough () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      finalize_for_session ctx ~session_id:"sess-exp-legacy";
      let args =
        `Assoc
          [
            ("session_id", `String "sess-exp-legacy");
            ("hypothesis", `String "legacy call");
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"experiment_start" ~args in
      check bool "legacy experiment_start ok" true ok;
      let json = parse_json body in
      check string "legacy response keeps status field"
        "running"
        (json |> member "status" |> to_string))

let test_trpg_action_submit_persists_events () =
  let base_dir = temp_dir () in
  let config, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      finalize_for_session ctx ~session_id:"sess-trpg-ok";
      let args =
        `Assoc
          [
            ("session_id", `String "sess-trpg-ok");
            ("action", `String "inspect market");
            ("intent", `String "gather clues");
            ("stakes", `String "medium");
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"trpg.action.submit" ~args in
      check bool "trpg.action.submit ok" true ok;
      let json = parse_json body in
      let room_id = json |> member "payload" |> member "room_id" |> to_string in
      let story_len =
        json
        |> member "payload"
        |> member "story_log"
        |> to_list |> List.length
      in
      check bool "story_log has entries" true (story_len >= 1);
      let events =
        match Trpg_engine_store.read_events ~base_dir:config.base_path ~room_id with
        | Ok ev -> ev
        | Error e -> fail ("read_events failed: " ^ e)
      in
      check bool "events appended" true (List.length events >= 2))

let () =
  Alcotest.run "Protocol GAME-VIEW"
    [
      ( "protocol",
        [
          test_case "precondition gate before finalize" `Quick
            test_precondition_required_without_finalize;
          test_case "decision finalize then experiment.start" `Quick
            test_decision_then_experiment_start;
          test_case "legacy alias experiment_start passthrough" `Quick
            test_legacy_alias_experiment_start_passthrough;
          test_case "trpg.action.submit persists events" `Quick
            test_trpg_action_submit_persists_events;
        ] );
    ]
