open Alcotest
open Masc_mcp
open Test_tool_team_session_support

let test_collaboration_evidence_counts_runtime_signals () =
  with_eio @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "tester"));
      let started_at = Time_compat.now () -. 60.0 in
      let planned_end_at = started_at +. 600.0 in
      let session =
        make_manual_session config ~goal:"collaboration evidence"
          ~created_by:"tester" ~agent_names:[ "alice"; "bob" ] ~min_agents:1
          ~checkpoint_interval_sec:30 ~started_at ~planned_end_at
          ~fallback_policy:Team_session_types.Fallback_cascade_then_task
          ~model_cascade:[ "glm:auto" ]
      in
      ignore
        (Team_session_store.update_session config session.session_id (fun s ->
             {
               s with
               broadcast_count = 1;
               portal_count = 1;
               updated_at_iso = Types.now_iso ();
             }));
      Team_session_store.append_event config session.session_id
        ~event_type:"team_turn"
        ~detail:
          (`Assoc
            [
              ("actor", `String "alice");
              ("kind", `String "broadcast");
              ("message", `String "sync");
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      ignore
        (Activity_graph.emit config ~room_id:session.room_id
           ~kind:"message.mentioned"
           ~actor:(Activity_graph.entity ~kind:"agent" "alice")
           ~subject:(Activity_graph.entity ~kind:"agent" "bob")
           ~payload:(`Assoc [ ("agent_name", `String "bob") ])
           ~tags:[ "message"; "mentioned" ] ());
      ignore
        (Activity_graph.emit config ~room_id:session.room_id
           ~kind:"board.posted"
           ~actor:(Activity_graph.entity ~kind:"agent" "bob")
           ~subject:(Activity_graph.entity ~kind:"post" "post-1")
           ~payload:(`Assoc [ ("post_id", `String "post-1") ])
           ~tags:[ "board"; "posted" ] ());
      let json =
        Dashboard_collaboration_evidence.json ~session_id:session.session_id
          ~config ()
      in
      let open Yojson.Safe.Util in
      let counts = json |> member "counts" in
      check int "team_turn_count" 1 (counts |> member "team_turn_count" |> to_int);
      check int "session_broadcast_count" 1
        (counts |> member "session_broadcast_count" |> to_int);
      check int "portal_count" 1 (counts |> member "portal_count" |> to_int);
      check int "mention_count" 1 (counts |> member "mention_count" |> to_int);
      check int "board_interaction_count" 1
        (counts |> member "board_interaction_count" |> to_int);
      check string "evidence_status" "strong"
        (json |> member "evidence_status" |> to_string))

let () =
  run "Dashboard_collaboration_evidence"
    [
      ( "collaboration_evidence",
        [
          test_case "counts runtime signals" `Quick
            test_collaboration_evidence_counts_runtime_signals;
        ] );
    ]
