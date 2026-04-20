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
      let config = Lib.Coord.default_config dir in
      f config)

let test_emit_and_list_events () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"agent.joined"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"agent" "claude")
           ~tags:[ "agent"; "join" ]
           ~payload:(`Assoc [ ("agent_name", `String "claude") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.created"
           ~actor:(Activity_graph.entity ~kind:"agent" "system")
           ~subject:(Activity_graph.entity ~kind:"task" "task-001")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Investigate drift") ])
           ());
      let events =
        Activity_graph.list_events config ~after_seq:0
          ~limit:10 ()
      in
      check int "two events" 2 (List.length events);
      check string "latest kind is task.created" "task.created"
        ((List.hd (List.rev events)).kind);
      let task_only =
        Activity_graph.list_events config
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
        Activity_graph.register "activity-test" ~push ~last_seq:0
          ~kind_filters:[ "task.created" ] ()
      in
      ignore
        (Activity_graph.emit config ~kind:"task.created"
           ~actor:(Activity_graph.entity ~kind:"agent" "system")
           ~subject:(Activity_graph.entity ~kind:"task" "task-101")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Match me") ])
           ());
      ignore
        (Activity_graph.emit config           ~kind:"message.broadcast"
           ~actor:(Activity_graph.entity ~kind:"agent" "system")
           ~tags:[ "message"; "broadcast" ]
           ~payload:(`Assoc [ ("content", `String "ignore") ])
           ());
      Activity_graph.unregister "activity-test";
      check int "only matching frame delivered" 1 (List.length !received))

let test_graph_json_summarizes_relationships () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"agent.joined"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"agent" "claude")
           ~tags:[ "agent"; "join" ]
           ~payload:(`Assoc [ ("agent_name", `String "claude") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.created"
           ~actor:(Activity_graph.entity ~kind:"agent" "system")
           ~subject:(Activity_graph.entity ~kind:"task" "task-003")
           ~tags:[ "task"; "create" ]
           ~payload:(`Assoc [ ("title", `String "Stabilize stream") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.claimed"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"task" "task-003")
           ~tags:[ "task"; "claim" ]
           ~payload:(`Assoc [ ("task_id", `String "task-003") ])
           ());
      let json =
        Activity_graph.graph_json config ~limit:20
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
        (Activity_graph.emit config           ~kind:"operation.started"
           ~actor:(Activity_graph.entity ~kind:"agent" "team-session")
           ~subject:(Activity_graph.entity ~kind:"operation" "sess-001")
           ~tags:[ "operation"; "operation.started" ]
           ~payload:(`Assoc [ ("session_id", `String "sess-001") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"team.turn"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"operation" "sess-001")
           ~tags:[ "operation"; "team.turn" ]
           ~payload:(`Assoc [ ("kind", `String "broadcast") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.started"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"task" "task-777")
           ~tags:[ "task"; "task.started" ]
           ~payload:(`Assoc [ ("task_id", `String "task-777") ])
           ());
      ignore
        (Activity_graph.emit config           ~kind:"board.posted"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"post" "post-42")
           ~tags:[ "board"; "board.posted" ]
           ~payload:(`Assoc [ ("post_id", `String "post-42") ])
           ());
      ignore
        (Activity_graph.emit config           ~kind:"board.voted"
           ~actor:(Activity_graph.entity ~kind:"agent" "gemini")
           ~subject:(Activity_graph.entity ~kind:"post" "post-42")
           ~tags:[ "board"; "board.voted" ]
           ~payload:(`Assoc [ ("target_id", `String "post-42") ])
           ());
      let json =
        Activity_graph.graph_json config ~limit:20
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

let test_graph_json_reports_kind_counts_and_heatmap_totals () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"message.broadcast"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~tags:[ "message"; "broadcast" ]
           ~payload:(`Assoc [ ("content", `String "hello") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"message.broadcast"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~tags:[ "message"; "broadcast" ]
           ~payload:(`Assoc [ ("content", `String "world") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.started"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"task" "task-900")
           ~tags:[ "task"; "task.started" ]
           ~payload:(`Assoc [ ("task_id", `String "task-900") ])
           ());
      let json =
        Activity_graph.graph_json config ~limit:20
          ~timeline_limit:10 ()
      in
      let open Yojson.Safe.Util in
      let kind_counts = json |> member "kind_counts" in
      let heatmap = json |> member "heatmap" in
      let matrix = heatmap |> member "matrix" |> to_list in
      check int "message.broadcast count" 2
        (kind_counts |> member "message.broadcast" |> to_int);
      check int "task.started count" 1
        (kind_counts |> member "task.started" |> to_int);
      check int "heatmap total matches filtered events" 3
        (heatmap |> member "total" |> to_int);
      check int "heatmap rows" 7 (List.length matrix);
      check bool "heatmap rows expose 24 hours" true
        (List.for_all (fun row -> List.length (to_list row) = 24) matrix))

let test_agent_spans_json_honors_since_ms () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"task.started"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"task" "task-old")
           ~tags:[ "task"; "task.started" ]
           ~payload:(`Assoc [ ("task_id", `String "task-old") ])
           ());
      ignore (Unix.select [] [] [] 0.02);
      let cutoff_ms = int_of_float (Time_compat.now () *. 1000.0) in
      ignore
        (Activity_graph.emit config ~kind:"task.started"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"task" "task-new")
           ~tags:[ "task"; "task.started" ]
           ~payload:(`Assoc [ ("task_id", `String "task-new") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.done"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~subject:(Activity_graph.entity ~kind:"task" "task-new")
           ~tags:[ "task"; "task.done" ]
           ~payload:(`Assoc [ ("task_id", `String "task-new") ])
           ());
      let json =
        Activity_graph.agent_spans_json config          ~since_ms:cutoff_ms ~limit:20 ()
      in
      let open Yojson.Safe.Util in
      let spans = json |> member "spans" |> to_list in
      check int "only recent span remains" 1 (List.length spans);
      check string "recent span label kept" "task-new"
        (List.hd spans |> member "label" |> to_string))

let test_parse_since_ms_supports_minutes () =
  check (option int) "5m parses" (Some (5 * 60 * 1000))
    (Lib.Server_activity_http.parse_since_ms "5m");
  check (option int) "1h still parses" (Some (3600 * 1000))
    (Lib.Server_activity_http.parse_since_ms "1h")

let test_span_status_of_string_handles_ended_round_trip () =
  check string "ended round-trips explicitly" "ended"
    (Activity_graph.span_status_of_string "ended"
     |> Activity_graph.span_status_to_string)

let test_span_status_of_string_keeps_legacy_unknown_fallback () =
  check string "unknown falls back to ended" "ended"
    (Activity_graph.span_status_of_string "definitely-not-a-status"
     |> Activity_graph.span_status_to_string)

let test_span_status_of_string_opt_returns_none_for_unknown () =
  (* #8605 family: strict variant exposes unknown wires explicitly so
     callers can react instead of being silently coerced to Span_ended. *)
  check (option string) "unknown -> None" None
    (Activity_graph.span_status_of_string_opt "definitely-not-a-status"
     |> Option.map Activity_graph.span_status_to_string);
  check (option string) "ended -> Some ended" (Some "ended")
    (Activity_graph.span_status_of_string_opt "ended"
     |> Option.map Activity_graph.span_status_to_string);
  check (option string) "open -> Some open" (Some "open")
    (Activity_graph.span_status_of_string_opt "open"
     |> Option.map Activity_graph.span_status_to_string)

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
          test_case "graph summary exposes kind counts and full heatmap totals"
            `Quick test_graph_json_reports_kind_counts_and_heatmap_totals;
          test_case "agent spans honor since filter" `Quick
            test_agent_spans_json_honors_since_ms;
          test_case "parse_since_ms supports minutes" `Quick
            test_parse_since_ms_supports_minutes;
          test_case "span_status parses ended explicitly" `Quick
            test_span_status_of_string_handles_ended_round_trip;
          test_case "span_status keeps unknown fallback" `Quick
            test_span_status_of_string_keeps_legacy_unknown_fallback;
          test_case "span_status_opt None for unknown" `Quick
            test_span_status_of_string_opt_returns_none_for_unknown;
        ] );
    ]
