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
  let store = Trpg.Store.make_sqlite ~base_dir in
  let ctx : Tool_protocol_game_view.context =
    {
      config;
      store;
      agent_name = "tester";
      trpg_keeper_call = None;
      trpg_keeper_probe = None;
      trpg_dm_voice_emit = None;
    }
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
        match Trpg.Engine_store.read_events ~base_dir:config.base_path ~room_id with
        | Ok ev -> ev
        | Error e -> fail ("read_events failed: " ^ e)
      in
      check bool "events appended" true (List.length events >= 2))

let test_trpg_world_query_requires_open () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let ok, body =
        dispatch_exn ctx ~name:"trpg.world.query"
          ~args:(`Assoc [ ("session_id", `String "wq-precond-1") ])
      in
      check bool "world.query should fail before open" false ok;
      check string "error code"
        "PRECONDITION_REQUIRED"
        (body |> parse_json |> member "payload" |> member "code" |> to_string))

let test_trpg_world_query_default_room_and_skills () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let _ =
        dispatch_exn ctx ~name:"client.session.open"
          ~args:(`Assoc [ ("session_id", `String "wq-default-1") ])
      in
      let ok, body =
        dispatch_exn ctx ~name:"trpg.world.query"
          ~args:(`Assoc [ ("session_id", `String "wq-default-1") ])
      in
      check bool "world.query ok" true ok;
      let json = parse_json body in
      check string "default room_id"
        "session-wq-default-1"
        (json |> member "payload" |> member "room_id" |> to_string);
      check string "self name"
        "tester"
        (json |> member "payload" |> member "self" |> member "name" |> to_string);
      let skills =
        json
        |> member "payload"
        |> member "available_skills"
        |> to_list |> List.map to_string
      in
      check bool "fallback skill includes observe" true (List.mem "observe" skills))

let next_jsonl_seq_or_fail base_dir room_id =
  match Trpg.Engine_store.read_events ~base_dir ~room_id with
  | Ok [] -> 1
  | Ok events ->
      List.fold_left
        (fun acc (ev : Trpg.Engine_event.t) -> max acc ev.seq)
        0 events
      + 1
  | Error e -> fail ("read_events failed: " ^ e)

let test_trpg_world_query_merge_and_visibility () =
  let base_dir = temp_dir () in
  let config, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      finalize_for_session ctx ~session_id:"wq-merge-1";
      let room_id = "session-wq-merge-1" in
      let _ =
        dispatch_exn ctx ~name:"client.session.open"
          ~args:(`Assoc [ ("session_id", `String "wq-merge-1") ])
      in
      let ok_turn, _ =
        dispatch_exn ctx ~name:"trpg.turn.advance"
          ~args:
            (`Assoc
              [ ("room_id", `String room_id); ("phase", `String "round") ])
      in
      check bool "turn.advance ok" true ok_turn;
      let ok_action, _ =
        dispatch_exn ctx ~name:"trpg.action.submit"
          ~args:
            (`Assoc
              [
                ("session_id", `String "wq-merge-1");
                ("room_id", `String room_id);
                ("action", `String "harvest");
              ])
      in
      check bool "action.submit ok" true ok_action;
      let injected_seq = next_jsonl_seq_or_fail config.base_path room_id in
      let injected =
        Trpg.Engine_event.make ~seq:injected_seq ~room_id ~ts:(Types.now_iso ())
          ~event_type:Trpg.Engine_event.World_event ~actor_id:"npc-1"
          ~payload:
            (`Assoc
              [
                ("public_note", `String "wind rises");
                ("secret_token", `String "hidden");
                ("private_note", `String "hidden-too");
                ("risk_ack", `String "internal-only");
              ])
          ()
      in
      (match Trpg.Engine_store.append_event ~base_dir:config.base_path ~event:injected with
      | Ok () -> ()
      | Error e -> fail ("append injected event failed: " ^ e));
      let ok, body =
        dispatch_exn ctx ~name:"trpg.world.query"
          ~args:
            (`Assoc
              [
                ("session_id", `String "wq-merge-1");
                ("room_id", `String room_id);
                ("after_seq", `Int 0);
                ("event_limit", `Int 10);
              ])
      in
      check bool "world.query ok" true ok;
      let json = parse_json body in
      check bool "source jsonl >= 3" true
        ((json
         |> member "payload"
         |> member "source_counts"
         |> member "jsonl"
         |> to_int)
        >= 3);
      check bool "source sqlite >= 1" true
        ((json
         |> member "payload"
         |> member "source_counts"
         |> member "sqlite"
         |> to_int)
        >= 1);
      let events =
        json |> member "payload" |> member "events_since" |> to_list
      in
      let world_event =
        events
        |> List.find_opt (fun ev ->
               ev |> member "type" |> to_string = "world.event")
      in
      check bool "world.event exists" true (Option.is_some world_event);
      (match world_event with
      | Some ev -> (
          match ev |> member "payload" with
          | `Assoc fields ->
              check bool "secret removed" false (List.mem_assoc "secret_token" fields);
              check bool "private removed" false (List.mem_assoc "private_note" fields);
              check bool "risk_ack removed" false (List.mem_assoc "risk_ack" fields)
          | _ -> fail "payload should be object")
      | None -> ());
      let ok_after, body_after =
        dispatch_exn ctx ~name:"trpg.world.query"
          ~args:
            (`Assoc
              [
                ("session_id", `String "wq-merge-1");
                ("room_id", `String room_id);
                ("after_seq", `Int 999);
                ("event_limit", `Int 10);
              ])
      in
      check bool "world.query after_seq ok" true ok_after;
      check int "after_seq filters all"
        0
        ( body_after
        |> parse_json
        |> member "payload"
        |> member "events_since"
        |> to_list
        |> List.length );
      let ok_limited, body_limited =
        dispatch_exn ctx ~name:"trpg.world.query"
          ~args:
            (`Assoc
              [
                ("session_id", `String "wq-merge-1");
                ("room_id", `String room_id);
                ("event_limit", `Int 1);
              ])
      in
      check bool "world.query event_limit ok" true ok_limited;
      check bool "event_limit applies" true
        (( body_limited
         |> parse_json
         |> member "payload"
         |> member "events_since"
         |> to_list
         |> List.length )
        <= 1))

let test_trpg_session_protocol_bootstrap () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let ok_preset, body_preset =
        dispatch_exn ctx ~name:"trpg.preset.list" ~args:(`Assoc [])
      in
      check bool "preset.list ok" true ok_preset;
      check bool "has dm presets" true
        ((body_preset |> parse_json |> member "payload" |> member "dm_presets" |> to_list |> List.length) >= 1);

      let session_id = "proto-boot-1" in
      let ok_pool, body_pool =
        dispatch_exn ctx ~name:"trpg.pool.generate"
          ~args:
            (`Assoc
              [
                ("session_id", `String session_id);
                ("pool_size", `Int 6);
                ("party_size", `Int 4);
                ("seed", `Int 13);
              ])
      in
      check bool "pool.generate ok" true ok_pool;
      let payload_pool = body_pool |> parse_json |> member "payload" in
      let pool = payload_pool |> member "pool" |> to_list in
      let suggested_ids = payload_pool |> member "suggested_party_ids" |> to_list in
      check int "pool size" 6 (List.length pool);
      check int "suggested size" 4 (List.length suggested_ids);

      let ok_party, body_party =
        dispatch_exn ctx ~name:"trpg.party.select"
          ~args:
            (`Assoc
              [
                ("session_id", `String session_id);
                ("pool", `List pool);
                ("selected_player_ids", `List suggested_ids);
              ])
      in
      check bool "party.select ok" true ok_party;
      let selected_party =
        body_party |> parse_json |> member "payload" |> member "party" |> to_list
      in
      check int "selected party size" 4 (List.length selected_party);

      let ok_start, body_start =
        dispatch_exn ctx ~name:"trpg.session.start"
          ~args:
            (`Assoc
              [
                ("session_id", `String session_id);
                ("party", `List selected_party);
                ("phase", `String "briefing");
              ])
      in
      check bool "session.start ok" true ok_start;
      let payload_start = body_start |> parse_json |> member "payload" in
      let room_id = payload_start |> member "room_id" |> to_string in
      check bool "room_id derived from session" true (String.length room_id > 0);
      let events = payload_start |> member "events" |> to_list in
      let has_session_started =
        List.exists
          (fun ev ->
            try ev |> member "type" |> to_string = "session.started" with _ -> false)
          events
      in
      check bool "session.started emitted" true has_session_started;

      let ok_intrv, body_intrv =
        dispatch_exn ctx ~name:"trpg.intervention.submit"
          ~args:
            (`Assoc
              [
                ("room_id", `String room_id);
                ("session_id", `String session_id);
                ("intervention_type", `String "nudge");
                ("reason", `String "human small tweak");
                ("payload", `Assoc [ ("delta", `Float 0.1) ]);
              ])
      in
      check bool "intervention.submit ok" true ok_intrv;
      check string "intervention status"
        "pending"
        (body_intrv |> parse_json |> member "payload" |> member "status" |> to_string))

let test_client_session_open_success () =
  let base_dir = temp_dir () in
  let config, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let args =
        `Assoc
          [
            ("session_id", `String "client-sess-1");
            ("trace_id", `String "trace-abc");
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"client.session.open" ~args in
      check bool "client.session.open ok" true ok;
      let json = parse_json body in
      check string "payload status"
        "opened"
        (json |> member "payload" |> member "status" |> to_string);
      check string "trace_id"
        "trace-abc"
        (json |> member "payload" |> member "trace_id" |> to_string);
      match Game_view_state.get_client_session config ~session_id:"client-sess-1" with
      | Some s ->
          check string "stored session id" "client-sess-1" s.session_id;
          check string "stored agent" "tester" s.agent_name
      | None -> fail "session should be stored")

let test_client_session_open_idempotent_refresh () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let first_args =
        `Assoc
          [
            ("session_id", `String "client-sess-idem");
            ("trace_id", `String "trace-first");
          ]
      in
      let ok1, body1 = dispatch_exn ctx ~name:"client.session.open" ~args:first_args in
      check bool "first open ok" true ok1;
      let first_seen =
        body1 |> parse_json |> member "payload" |> member "last_seen" |> to_float
      in
      Unix.sleepf 0.01;
      let second_args = `Assoc [ ("session_id", `String "client-sess-idem") ] in
      let ok2, body2 = dispatch_exn ctx ~name:"client.session.open" ~args:second_args in
      check bool "second open ok" true ok2;
      let json2 = parse_json body2 in
      let second_seen = json2 |> member "payload" |> member "last_seen" |> to_float in
      check bool "last_seen should advance" true (second_seen >= first_seen);
      check string "trace persisted"
        "trace-first"
        (json2 |> member "payload" |> member "trace_id" |> to_string))

let test_client_subscribe_requires_open () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let args =
        `Assoc
          [
            ("session_id", `String "not-opened");
            ("topics", `List [ `String "trpg.events" ]);
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"client.state.subscribe" ~args in
      check bool "subscribe should fail before open" false ok;
      let json = parse_json body in
      check string "error code"
        "PRECONDITION_REQUIRED"
        (json |> member "payload" |> member "code" |> to_string))

let test_client_subscribe_partial_and_transport () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let _ =
        dispatch_exn ctx ~name:"client.session.open"
          ~args:(`Assoc [ ("session_id", `String "client-sub-1") ])
      in
      let args =
        `Assoc
          [
            ("session_id", `String "client-sub-1");
            ( "topics",
              `List
                [
                  `String "trpg.events";
                  `String "trpg.state";
                  `String "unknown.topic";
                  `String "trpg.events";
                ] );
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"client.state.subscribe" ~args in
      check bool "subscribe ok" true ok;
      let json = parse_json body in
      let accepted =
        json
        |> member "payload"
        |> member "accepted_topics"
        |> to_list |> List.map to_string
      in
      let rejected =
        json
        |> member "payload"
        |> member "rejected_topics"
        |> to_list |> List.map to_string
      in
      check bool "accept trpg.events" true (List.mem "trpg.events" accepted);
      check bool "accept trpg.state" true
        (List.mem "trpg.state" accepted);
      check bool "reject unknown topic" true (List.mem "unknown.topic" rejected);
      check bool "dedup trpg.events" true
        (List.length (List.filter (fun t -> t = "trpg.events") accepted) <= 1);
      check string "transport primary"
        "sse"
        (json |> member "payload" |> member "transport" |> member "primary" |> to_string);
      check string "trpg.events fallback tool"
        "trpg.stream.read"
        ( json
        |> member "payload"
        |> member "transport"
        |> member "pull_fallback"
        |> member "trpg.events"
        |> member "tool"
        |> to_string ))

let test_client_input_requires_open () =
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let args =
        `Assoc
          [
            ("session_id", `String "client-in-1");
            ("input", `String "human says hi");
          ]
      in
      let ok, body = dispatch_exn ctx ~name:"client.input.submit" ~args in
      check bool "client.input.submit should fail before open" false ok;
      let json = parse_json body in
      check string "error code"
        "PRECONDITION_REQUIRED"
        (json |> member "payload" |> member "code" |> to_string))

let test_client_input_submit_and_approve () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let _ =
        dispatch_exn ctx ~name:"client.session.open"
          ~args:(`Assoc [ ("session_id", `String "client-in-2") ])
      in
      let submit_args =
        `Assoc
          [
            ("session_id", `String "client-in-2");
            ("input", `String "human chooses route C");
          ]
      in
      let ok_submit, submit_body =
        dispatch_exn ctx ~name:"client.input.submit" ~args:submit_args
      in
      check bool "submit ok" true ok_submit;
      let submit_json = parse_json submit_body in
      let input_id =
        submit_json |> member "payload" |> member "input_id" |> to_string
      in
      check string "submit status"
        "pending"
        (submit_json |> member "payload" |> member "status" |> to_string);
      let approve_args =
        `Assoc
          [
            ("session_id", `String "client-in-2");
            ("input_id", `String input_id);
          ]
      in
      let ok_approve, approve_body =
        dispatch_exn ctx ~name:"client.input.approve" ~args:approve_args
      in
      check bool "approve ok" true ok_approve;
      let approve_json = parse_json approve_body in
      check string "approve status"
        "approved"
        (approve_json |> member "payload" |> member "status" |> to_string);
      let ok_reapprove, reapprove_body =
        dispatch_exn ctx ~name:"client.input.approve" ~args:approve_args
      in
      check bool "re-approve should fail" false ok_reapprove;
      check string "re-approve code"
        "CONFLICT"
        (reapprove_body |> parse_json |> member "payload" |> member "code" |> to_string))

let test_client_snapshot_get () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let _, ctx = mk_ctx base_dir in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      finalize_for_session ctx ~session_id:"client-snap-1";
      let _ =
        dispatch_exn ctx ~name:"client.session.open"
          ~args:(`Assoc [ ("session_id", `String "client-snap-1") ])
      in
      let _ =
        dispatch_exn ctx ~name:"client.input.submit"
          ~args:
            (`Assoc
              [
                ("session_id", `String "client-snap-1");
                ("input", `String "wait for sunset");
              ])
      in
      let _ =
        dispatch_exn ctx ~name:"trpg.action.submit"
          ~args:
            (`Assoc
              [
                ("session_id", `String "client-snap-1");
                ("action", `String "scout gate");
              ])
      in
      let ok, body =
        dispatch_exn ctx ~name:"client.snapshot.get"
          ~args:
            (`Assoc
              [
                ("session_id", `String "client-snap-1");
                ("max_events", `Int 5);
              ])
      in
      check bool "snapshot ok" true ok;
      let json = parse_json body in
      check bool "latest decision exists" true
        (match json |> member "payload" |> member "latest_decision" with
         | `Null -> false
         | _ -> true);
      check bool "input pending count >= 1" true
        ((json
         |> member "payload"
         |> member "input_queue"
         |> member "pending_count"
         |> to_int)
        >= 1);
      check bool "trpg events included" true
        ((json |> member "payload" |> member "trpg" |> member "event_count" |> to_int) >= 2))

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run "Protocol GAME-VIEW"
    [
      ( "protocol",
        [
          test_case "trpg.action.submit persists events" `Quick
            test_trpg_action_submit_persists_events;
          test_case "trpg.world.query requires open" `Quick
            test_trpg_world_query_requires_open;
          test_case "trpg.world.query default room + skills" `Quick
            test_trpg_world_query_default_room_and_skills;
          test_case "trpg.world.query merge + visibility" `Quick
            test_trpg_world_query_merge_and_visibility;
          test_case "trpg session bootstrap protocol flow" `Quick
            test_trpg_session_protocol_bootstrap;
          test_case "client.session.open success" `Quick
            test_client_session_open_success;
          test_case "client.session.open idempotent refresh" `Quick
            test_client_session_open_idempotent_refresh;
          test_case "client.state.subscribe requires open" `Quick
            test_client_subscribe_requires_open;
          test_case "client.state.subscribe partial + transport" `Quick
            test_client_subscribe_partial_and_transport;
          test_case "client.input.submit requires open" `Quick
            test_client_input_requires_open;
          test_case "client.input submit+approve" `Quick
            test_client_input_submit_and_approve;
          test_case "client.snapshot.get" `Quick
            test_client_snapshot_get;
        ] );
    ]
