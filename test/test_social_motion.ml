module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_social_motion" "" in
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
        (Lib.Social_motion.emit config ~room_id:"default" ~kind:"agent.joined"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "claude")
           ~subject:(Lib.Social_motion.entity ~kind:"agent" "claude")
           ~tags:[ "agent"; "join" ]
           ~payload:(`Assoc [ ("agent_name", `String "claude") ])
           ());
      ignore
        (Lib.Social_motion.emit config ~room_id:"default" ~kind:"task.created"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "system")
           ~subject:(Lib.Social_motion.entity ~kind:"task" "task-001")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Investigate drift") ])
           ());
      let events =
        Lib.Social_motion.list_events config ~room_id:"default" ~after_seq:0
          ~limit:10 ()
      in
      check int "two events" 2 (List.length events);
      check string "latest kind is task.created" "task.created"
        ((List.hd (List.rev events)).kind);
      let task_only =
        Lib.Social_motion.list_events config ~room_id:"default"
          ~kinds:[ "task.created" ] ~after_seq:0 ~limit:10 ()
      in
      check int "task filter" 1 (List.length task_only))

let test_filtered_client_receives_matching_events () =
  with_config (fun config ->
      let received = ref [] in
      let push frame = received := frame :: !received in
      let _client_id =
        Lib.Social_motion.register "social-test" ~push ~last_seq:0
          ~room_filter:"focus" ~kind_filters:[ "task.created" ] ()
      in
      ignore
        (Lib.Social_motion.emit config ~room_id:"focus" ~kind:"task.created"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "system")
           ~subject:(Lib.Social_motion.entity ~kind:"task" "task-101")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Match me") ])
           ());
      ignore
        (Lib.Social_motion.emit config ~room_id:"focus"
           ~kind:"message.broadcast"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "system")
           ~tags:[ "message"; "broadcast" ]
           ~payload:(`Assoc [ ("content", `String "ignore") ])
           ());
      Lib.Social_motion.unregister "social-test";
      check int "only matching frame delivered" 1 (List.length !received))

let test_graph_json_summarizes_relationships () =
  with_config (fun config ->
      ignore
        (Lib.Social_motion.emit config ~room_id:"default" ~kind:"agent.joined"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "claude")
           ~subject:(Lib.Social_motion.entity ~kind:"agent" "claude")
           ~tags:[ "agent"; "join" ]
           ~payload:(`Assoc [ ("agent_name", `String "claude") ])
           ());
      ignore
        (Lib.Social_motion.emit config ~room_id:"default" ~kind:"task.created"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "system")
           ~subject:(Lib.Social_motion.entity ~kind:"task" "task-003")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Stabilize stream") ])
           ());
      ignore
        (Lib.Social_motion.emit config ~room_id:"default" ~kind:"task.claimed"
           ~actor:(Lib.Social_motion.entity ~kind:"agent" "claude")
           ~subject:(Lib.Social_motion.entity ~kind:"task" "task-003")
           ~tags:[ "task"; "claim" ]
           ~payload:(`Assoc [ ("task_id", `String "task-003") ])
           ());
      let json =
        Lib.Social_motion.graph_json config ~room_id:"default" ~limit:20
          ~timeline_limit:10 ()
      in
      let open Yojson.Safe.Util in
      check bool "graph has nodes" true
        (List.length (json |> member "nodes" |> to_list) >= 3);
      check bool "graph has edges" true
        (List.length (json |> member "edges" |> to_list) >= 2);
      check int "timeline contains all events" 3
        (List.length (json |> member "timeline" |> to_list)))

let () =
  Eio_main.run @@ fun _env ->
  run "Social Motion"
    [
      ( "core",
        [
          test_case "emit and list events" `Quick test_emit_and_list_events;
          test_case "filtered client receives matching events" `Quick
            test_filtered_client_receives_matching_events;
          test_case "graph summary builds nodes and edges" `Quick
            test_graph_json_summarizes_relationships;
        ] );
    ]
