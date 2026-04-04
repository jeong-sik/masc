open Alcotest
open Masc_mcp
open Test_tool_team_session_support
module U = Yojson.Safe.Util

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
           ~payload:
             (`Assoc
               [
                 ("agent_name", `String "bob");
                 ("session_id", `String session.session_id);
               ])
           ~tags:[ "message"; "mentioned" ] ());
      ignore
        (Activity_graph.emit config ~room_id:session.room_id
           ~kind:"board.posted"
           ~actor:(Activity_graph.entity ~kind:"agent" "bob")
           ~subject:(Activity_graph.entity ~kind:"post" "post-1")
           ~payload:
             (`Assoc
               [
                 ("post_id", `String "post-1");
                 ("session_id", `String session.session_id);
               ])
           ~tags:[ "board"; "posted" ] ());
      let json =
        Dashboard_collaboration_evidence.json ~session_id:session.session_id
          ~config ()
      in
      let open U in
      let counts = json |> member "counts" in
      check int "team_turn_count" 1 (counts |> member "team_turn_count" |> to_int);
      check int "session_broadcast_count" 1
        (counts |> member "session_broadcast_count" |> to_int);
      check int "portal_count" 1 (counts |> member "portal_count" |> to_int);
      check int "mention_count" 1 (counts |> member "mention_count" |> to_int);
      check int "board_interaction_count" 1
        (counts |> member "board_interaction_count" |> to_int);
      check int "unlinked room activity count" 0
        (counts |> member "unlinked_activity_count" |> to_int);
      check string "evidence_status" "strong"
        (json |> member "evidence_status" |> to_string))

let test_append_event_injects_linkage_metadata () =
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
        make_manual_session config ~goal:"linkage metadata"
          ~created_by:"tester" ~agent_names:[ "alice" ] ~min_agents:1
          ~checkpoint_interval_sec:30 ~started_at ~planned_end_at
          ~fallback_policy:Team_session_types.Fallback_cascade_then_task
          ~model_cascade:[ "glm:auto" ]
      in
      ignore
        (Team_session_store.update_session config session.session_id (fun s ->
             {
               s with
               operation_id = Some "op-linkage-1";
               updated_at_iso = Types.now_iso ();
             }));
      Team_session_store.append_event config session.session_id
        ~event_type:"team_step_spawn_requested"
        ~detail:
          (`Assoc
            [
              ("actor", `String "tester");
              ("worker_run_id", `String "wr-linkage-1");
              ("message", `String "spawn requested");
            ]);
      let event_json =
        Team_session_store.read_events config session.session_id
        |> List.hd
        |> fun json -> json |> U.member "detail"
      in
      let open U in
      check string "event session id injected" session.session_id
        (event_json |> member "session_id" |> to_string);
      check string "event operation id injected" "op-linkage-1"
        (event_json |> member "operation_id" |> to_string);
      check string "event worker run id preserved" "wr-linkage-1"
        (event_json |> member "worker_run_id" |> to_string);
      let activity_json =
        Activity_graph.list_events config ~room_id:session.room_id ~after_seq:0
          ~limit:20 ()
        |> List.find (fun (event : Activity_graph.event) ->
               String.equal event.kind "team.spawn_requested")
      in
      check string "activity payload session id injected" session.session_id
        (activity_json.payload |> member "session_id" |> to_string);
      check string "activity payload operation id injected" "op-linkage-1"
        (activity_json.payload |> member "operation_id" |> to_string))

let test_collaboration_evidence_tracks_unlinked_room_noise () =
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
        make_manual_session config ~goal:"room noise separation"
          ~created_by:"tester" ~agent_names:[ "alice"; "bob" ] ~min_agents:1
          ~checkpoint_interval_sec:30 ~started_at ~planned_end_at
          ~fallback_policy:Team_session_types.Fallback_cascade_then_task
          ~model_cascade:[ "glm:auto" ]
      in
      ignore
        (Activity_graph.emit config ~room_id:session.room_id
           ~kind:"message.mentioned"
           ~actor:(Activity_graph.entity ~kind:"agent" "alice")
           ~subject:(Activity_graph.entity ~kind:"agent" "bob")
           ~payload:
             (`Assoc
               [
                 ("agent_name", `String "bob");
                 ("session_id", `String session.session_id);
               ])
           ~tags:[ "message"; "mentioned" ] ());
      ignore
        (Activity_graph.emit config ~room_id:session.room_id
           ~kind:"message.broadcast"
           ~actor:(Activity_graph.entity ~kind:"agent" "system")
           ~payload:(`Assoc [ ("content", `String "unlinked broadcast") ])
           ~tags:[ "message"; "broadcast" ] ());
      let json =
        Dashboard_collaboration_evidence.json ~session_id:session.session_id
          ~config ()
      in
      let open U in
      let counts = json |> member "counts" in
      check int "linked mention count" 1
        (counts |> member "mention_count" |> to_int);
      check int "unlinked room activity count" 1
        (counts |> member "unlinked_activity_count" |> to_int);
      check int "explicit linked room activity count" 1
        (counts |> member "explicit_linked_activity_count" |> to_int);
      let linkage = json |> member "linkage" in
      check string "linkage policy" "explicit_first"
        (linkage |> member "policy" |> to_string);
      check string "linkage gap wording"
        "namespace activity exists without explicit session/operation linkage"
        (linkage |> member "gaps" |> index 0 |> to_string);
      check string "strong detail wording"
        "team_turn, broadcast/portal, activity 이벤트, proof 경로를 함께 확인할 수 있습니다."
        (json |> member "detail" |> to_string);
      check bool "linkage gaps populated" true
        ((linkage |> member "gaps" |> to_list) <> []))

let test_recent_unlinked_activity_preserves_chronological_order () =
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
        make_manual_session config ~goal:"recent unlinked ordering"
          ~created_by:"tester" ~agent_names:[ "alice"; "bob" ] ~min_agents:1
          ~checkpoint_interval_sec:30 ~started_at ~planned_end_at
          ~fallback_policy:Team_session_types.Fallback_cascade_then_task
          ~model_cascade:[ "glm:auto" ]
      in
      List.iter
        (fun index ->
          ignore
            (Activity_graph.emit config ~room_id:session.room_id
               ~kind:"message.broadcast"
               ~actor:(Activity_graph.entity ~kind:"agent" "system")
               ~payload:
                 (`Assoc
                   [
                     ("content", `String (Printf.sprintf "unlinked-%d" index));
                   ])
               ~tags:[ "message"; "broadcast" ] ()))
        [ 1; 2; 3; 4; 5; 6; 7; 8 ];
      let json =
        Dashboard_collaboration_evidence.json ~session_id:session.session_id
          ~config ()
      in
      let summaries =
        json |> U.member "recent_unlinked_activity" |> U.to_list
        |> List.map (fun item -> item |> U.member "summary" |> U.to_string)
      in
      check (list string) "keeps most recent six in order"
        [ "unlinked-3"; "unlinked-4"; "unlinked-5"; "unlinked-6"; "unlinked-7";
          "unlinked-8" ]
        summaries)

let test_emit_message_activity_normalizes_evidence_refs () =
  with_eio @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "tester"));
      Room_state.emit_message_activity config ~from_agent:"alice"
        ~content:"normalized evidence refs" ~mention:None
        ~evidence_refs:[ " trace:abc "; ""; "trace:abc"; " proof:xyz " ] ();
      let payload =
        Activity_graph.list_events config ~room_id:"default" ~after_seq:0
          ~limit:20 ()
        |> List.find (fun (event : Activity_graph.event) ->
               String.equal event.kind "message.broadcast"
               && U.member "content" event.payload
                  = `String "normalized evidence refs")
        |> fun (event : Activity_graph.event) -> event.payload
      in
      check (list string) "evidence refs normalized"
        [ "trace:abc"; "proof:xyz" ]
        (payload |> U.member "evidence_refs" |> U.to_list |> List.map U.to_string))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "Dashboard_collaboration_evidence"
    [
      ( "collaboration_evidence",
        [
          test_case "counts runtime signals" `Quick
            test_collaboration_evidence_counts_runtime_signals;
          test_case "append_event injects linkage metadata" `Quick
            test_append_event_injects_linkage_metadata;
          test_case "tracks unlinked room noise" `Quick
            test_collaboration_evidence_tracks_unlinked_room_noise;
          test_case "recent unlinked activity preserves order" `Quick
            test_recent_unlinked_activity_preserves_chronological_order;
          test_case "emit message activity normalizes evidence refs" `Quick
            test_emit_message_activity_normalizes_evidence_refs;
        ] );
    ]
