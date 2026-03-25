module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_activity_graph" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let with_config f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room.default_config dir in
      f config)

let test_emit_and_list_events () =
  with_config (fun config ->
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"agent.joined"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~tags:[ "agent"; "join" ]
           ~payload:(`Assoc [ ("agent_name", `String "claude") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"task.created"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "system")
           ~subject:(Lib.Activity_graph.entity ~kind:"task" "task-001")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Investigate drift") ])
           ());
      let events =
        Lib.Activity_graph.list_events config ~room_id:"default" ~after_seq:0
          ~limit:10 ()
      in
      check int "two events" 2 (List.length events);
      check string "latest kind is task.created" "task.created"
        ((List.hd (List.rev events)).kind);
      let task_only =
        Lib.Activity_graph.list_events config ~room_id:"default"
          ~kinds:[ "task.created" ] ~after_seq:0 ~limit:10 ()
      in
      check int "task filter" 1 (List.length task_only))

let test_filtered_client_receives_matching_events () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      let received = ref [] in
      let push frame = received := frame :: !received in
      let _client_id =
        Lib.Activity_graph.register "activity-test" ~push ~last_seq:0
          ~room_filter:"focus" ~kind_filters:[ "task.created" ] ()
      in
      ignore
        (Lib.Activity_graph.emit config ~room_id:"focus" ~kind:"task.created"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "system")
           ~subject:(Lib.Activity_graph.entity ~kind:"task" "task-101")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Match me") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"focus"
           ~kind:"message.broadcast"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "system")
           ~tags:[ "message"; "broadcast" ]
           ~payload:(`Assoc [ ("content", `String "ignore") ])
           ());
      Lib.Activity_graph.unregister "activity-test";
      check int "only matching frame delivered" 1 (List.length !received))

let test_graph_json_summarizes_relationships () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"agent.joined"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~tags:[ "agent"; "join" ]
           ~payload:(`Assoc [ ("agent_name", `String "claude") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"task.created"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "system")
           ~subject:(Lib.Activity_graph.entity ~kind:"task" "task-003")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Stabilize stream") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"task.claimed"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Lib.Activity_graph.entity ~kind:"task" "task-003")
           ~tags:[ "task"; "claim" ]
           ~payload:(`Assoc [ ("task_id", `String "task-003") ])
           ());
      let json =
        Lib.Activity_graph.graph_json config ~room_id:"default" ~limit:20
          ~timeline_limit:10 ()
      in
      let open Yojson.Safe.Util in
      check bool "graph has nodes" true
        (List.length (json |> member "nodes" |> to_list) >= 3);
      check bool "graph has edges" true
        (List.length (json |> member "edges" |> to_list) >= 2);
      check int "timeline contains all events" 3
        (List.length (json |> member "timeline" |> to_list)))

let test_graph_json_tracks_runtime_activity_kinds () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default"
           ~kind:"operation.started"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "team-session")
           ~subject:(Lib.Activity_graph.entity ~kind:"operation" "sess-001")
           ~tags:[ "team_session"; "operation.started" ]
           ~payload:(`Assoc [ ("session_id", `String "sess-001") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"team.turn"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Lib.Activity_graph.entity ~kind:"operation" "sess-001")
           ~tags:[ "team_session"; "team.turn" ]
           ~payload:(`Assoc [ ("kind", `String "broadcast") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default" ~kind:"task.started"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Lib.Activity_graph.entity ~kind:"task" "task-777")
           ~tags:[ "task"; "task.started" ]
           ~payload:(`Assoc [ ("task_id", `String "task-777") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default"
           ~kind:"board.posted"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Lib.Activity_graph.entity ~kind:"post" "post-42")
           ~tags:[ "board"; "board.posted" ]
           ~payload:(`Assoc [ ("post_id", `String "post-42") ])
           ());
      ignore
        (Lib.Activity_graph.emit config ~room_id:"default"
           ~kind:"board.voted"
           ~actor:(Lib.Activity_graph.entity ~kind:"agent" "gemini")
           ~subject:(Lib.Activity_graph.entity ~kind:"post" "post-42")
           ~tags:[ "board"; "board.voted" ]
           ~payload:(`Assoc [ ("target_id", `String "post-42") ])
           ());
      let json =
        Lib.Activity_graph.graph_json config ~room_id:"default" ~limit:20
          ~timeline_limit:10 ()
      in
      let open Yojson.Safe.Util in
      let nodes = json |> member "nodes" |> to_list in
      let edges = json |> member "edges" |> to_list in
      let has_node id status =
        List.exists
          (fun node ->
            member "id" node = `String id
            && member "status" node = `String status)
          nodes
      in
      let has_edge kind =
        List.exists
          (fun edge -> member "kind" edge = `String kind)
          edges
      in
      check bool "operation node marked running" true
        (has_node "operation:sess-001" "running");
      check bool "task node marked in progress" true
        (has_node "task:task-777" "in_progress");
      check bool "team turn edge captured" true
        (has_edge "participates_in");
      check bool "board post edge captured" true
        (has_edge "posts");
      check bool "board vote edge captured" true
        (has_edge "votes_on"))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Activity Graph"
    [
      ( "core",
        [
          test_case "emit and list events" `Quick test_emit_and_list_events;
          test_case "filtered client receives matching events" `Quick
            test_filtered_client_receives_matching_events;
          test_case "graph summary builds nodes and edges" `Quick
            test_graph_json_summarizes_relationships;
          test_case "graph summary tracks runtime activity kinds" `Quick
            test_graph_json_tracks_runtime_activity_kinds;
        ] );
    ]
