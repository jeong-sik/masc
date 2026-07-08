module Lib = Masc

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
      let config = Lib.Workspace.default_config dir in
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

let test_events_json_derives_ide_context () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-9")
           ~tags:[
             "file:lib/keeper/keeper_tool_ide_runtime.ml:27";
             "task:task-42";
             "board:post-1";
             "comment:comment-7";
             "git:main";
             "log:turn-9";
           ]
           ~payload:
             (`Assoc
                [
                  ("goal_id", `String "goal-ide");
                  ("comment_id", `String "comment-7");
                  ("pr_number", `Int 15035);
                ])
           ());
      let json = Activity_graph.json_response config ~after_seq:0 ~limit:10 () in
      let open Yojson.Safe.Util in
      let event =
        match json |> member "events" |> to_list with
        | [ event ] -> event
        | events ->
          fail (Printf.sprintf "expected one event, got %d" (List.length events))
      in
      let context = event |> member "context" in
      check string "context file path" "lib/keeper/keeper_tool_ide_runtime.ml"
        (context |> member "file_path" |> to_string);
      check int "context line" 27 (context |> member "line" |> to_int);
      check string "context goal" "goal-ide"
        (context |> member "goal_id" |> to_string);
      check string "context task" "task-42"
        (context |> member "task_id" |> to_string);
      check string "context board" "post-1"
        (context |> member "board_post_id" |> to_string);
      check string "context comment" "comment-7"
        (context |> member "comment_id" |> to_string);
      check string "context pr" "15035"
        (context |> member "pr_id" |> to_string);
      check string "context git" "main"
        (context |> member "git_ref" |> to_string);
      check string "context log" "turn-9"
        (context |> member "log_id" |> to_string))

let test_events_json_normalizes_ide_context_file_paths () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-payload")
           ~tags:[]
           ~payload:
             (`Assoc
                [
                  ("file_path", `String " lib\\payload.ml ");
                  ("line", `Int 12);
                ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-tag")
           ~tags:[ "file: lib\\tag.ml:27" ]
           ~payload:(`Assoc [])
           ());
      let json = Activity_graph.json_response config ~after_seq:0 ~limit:10 () in
      let open Yojson.Safe.Util in
      match json |> member "events" |> to_list with
      | [ payload_event; tag_event ] ->
        let payload_context = payload_event |> member "context" in
        let tag_context = tag_event |> member "context" in
        check string "payload file path normalized" "lib/payload.ml"
          (payload_context |> member "file_path" |> to_string);
        check string "tag file path normalized" "lib/tag.ml"
          (tag_context |> member "file_path" |> to_string);
        check int "tag line kept" 27 (tag_context |> member "line" |> to_int)
      | events ->
        fail (Printf.sprintf "expected two events, got %d" (List.length events)))

let test_events_json_omits_unsafe_ide_context_file_paths () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-absolute")
           ~tags:[]
           ~payload:
             (`Assoc
                [
                  ("file_path", `String "/workspace/lib/payload.ml");
                  ("line", `Int 12);
                ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-drive")
           ~tags:[ "file:C:\\workspace\\lib\\tag.ml:27" ]
           ~payload:(`Assoc [])
           ());
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-traversal")
           ~tags:[ "file:lib/../tag.ml:31" ]
           ~payload:(`Assoc [])
           ());
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-mismatch")
           ~tags:[ "file:/workspace/lib/tag.ml:99" ]
           ~payload:
             (`Assoc
                [
                  ("file_path", `String "lib/payload.ml");
                  ("line", `Int 12);
                ])
           ());
      let json = Activity_graph.json_response config ~after_seq:0 ~limit:10 () in
      let open Yojson.Safe.Util in
      match json |> member "events" |> to_list with
      | [ payload_event; drive_event; traversal_event; mismatch_event ] ->
        let file_path_omitted event =
          match event |> member "context" with
          | `Null -> true
          | context -> context |> member "file_path" = `Null
        in
        List.iter
          (fun event ->
            check bool "unsafe file path omitted" true (file_path_omitted event))
          [ payload_event; drive_event; traversal_event ];
        check int "line survives without unsafe payload file path" 12
          (payload_event |> member "context" |> member "line" |> to_int);
        check bool "unsafe tag file line omitted" true
          (drive_event |> member "context" = `Null);
        let mismatch_context = mismatch_event |> member "context" in
        check string "unsafe tag keeps payload file path" "lib/payload.ml"
          (mismatch_context |> member "file_path" |> to_string);
        check int "unsafe tag keeps payload line" 12
          (mismatch_context |> member "line" |> to_int)
      | events ->
        fail
          (Printf.sprintf "expected four events, got %d" (List.length events)))

let test_events_json_ignores_invalid_derived_pr_number () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "sangsu")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-10")
           ~tags:[]
           ~payload:(`Assoc [ ("pr_number", `Int 0) ])
           ());
      let json = Activity_graph.json_response config ~after_seq:0 ~limit:10 () in
      let open Yojson.Safe.Util in
      let event =
        match json |> member "events" |> to_list with
        | [ event ] -> event
        | events ->
          fail (Printf.sprintf "expected one event, got %d" (List.length events))
      in
      let context = event |> member "context" in
      check bool "invalid pr number omitted" true
        (match context with
         | `Null -> true
         | _ -> context |> member "pr_id" |> fun value -> value = `Null))

let test_events_json_exposes_provenance_and_non_stale_latest_seq () =
  with_config (fun config ->
      let first =
        Activity_graph.emit config ~kind:"agent.joined"
          ~actor:(Activity_graph.entity ~kind:"agent" "claude")
          ~subject:(Activity_graph.entity ~kind:"agent" "claude")
          ~payload:(`Assoc [ ("agent_name", `String "claude") ])
          ()
      in
      let second =
        Activity_graph.emit config ~kind:"task.created"
          ~actor:(Activity_graph.entity ~kind:"agent" "system")
          ~subject:(Activity_graph.entity ~kind:"task" "task-activity")
          ~payload:(`Assoc [ ("task_id", `String "task-activity") ])
          ()
      in
      let seq_counter =
        Filename.concat
          (Filename.concat (Workspace_utils.masc_dir config) "activity-events")
          "_seq"
      in
      Fs_compat.save_file seq_counter (string_of_int first.seq);
      let json = Activity_graph.json_response config ~after_seq:0 ~limit:10 () in
      let open Yojson.Safe.Util in
      check string "surface" "/api/v1/activity/events"
        (json |> member "dashboard_surface" |> to_string);
      check string "source" "activity_graph_jsonl"
        (json |> member "source" |> to_string);
      check string "retention scope" "activity_events"
        (json |> member "retention" |> member "scope" |> to_string);
      check string "query kind list is empty" "[]"
        (json |> member "query" |> member "kinds" |> Yojson.Safe.to_string);
      check int "next cursor is newest returned event" second.seq
        (json |> member "next_after_seq" |> to_int);
      check int "latest matching seq sees JSONL rows" second.seq
        (json |> member "latest_matching_seq" |> to_int);
      check bool "latest seq does not move behind persisted rows" true
        ((json |> member "latest_seq" |> to_int) >= second.seq))

let test_emit_sanitizes_invalid_utf8_before_persisting () =
  with_config (fun config ->
      Safe_ops.reset_persistence_utf8_repair_stats_for_tests ();
      let replacement = "\xEF\xBF\xBD" in
      ignore
        (Activity_graph.emit config ~kind:"message.broadcast"
           ~actor:(Activity_graph.entity ~kind:"agent" "bad\xffactor")
           ~tags:[ "message"; "bad\xfftag" ]
           ~payload:(`Assoc [ ("content", `String "bad\xffpayload") ])
           ());
      let events =
        Activity_graph.list_events config ~after_seq:0 ~limit:10 ()
      in
      let event =
        match events with
        | [ event ] -> event
        | _ -> fail "expected one event"
      in
      let open Yojson.Safe.Util in
      check string "actor id repaired on write"
        ("bad" ^ replacement ^ "actor")
        (match event.actor with
         | Some actor -> actor.id
         | None -> fail "expected actor");
      check string "tag repaired on write"
        ("bad" ^ replacement ^ "tag")
        (match event.tags with
         | _ :: tag :: _ -> tag
         | tags ->
             fail
               (Printf.sprintf "expected second tag, got %d"
                  (List.length tags)));
      check string "payload repaired on write"
        ("bad" ^ replacement ^ "payload")
        (event.payload |> member "content" |> to_string);
      let stats = Safe_ops.persistence_utf8_repair_stats () in
      check int "read path did not repair activity graph row" 0
        stats.repaired_reads)

let test_read_self_heals_historic_invalid_utf8_event_file () =
  with_config (fun config ->
      Safe_ops.reset_persistence_utf8_repair_stats_for_tests ();
      let root = Filename.concat (Workspace_utils.masc_dir config) "activity-events" in
      let month_dir = Filename.concat root "2000-01" in
      Unix.mkdir root 0o755;
      Unix.mkdir month_dir 0o755;
      let event_path = Filename.concat month_dir "01.jsonl" in
      let raw_line =
        "{\"seq\":1,\"ts_ms\":1,\"ts_iso\":\"2000-01-01T00:00:00Z\",\
         \"workspace_id\":\"default\",\"kind\":\"message.broadcast\",\
         \"payload\":{\"content\":\"bad\xffpayload\"},\"tags\":[]}\n"
      in
      Fs_compat.save_file event_path raw_line;
      check bool "fixture starts invalid" false
        (String.is_valid_utf_8 (Fs_compat.load_file event_path));
      let events = Activity_graph.list_events config ~after_seq:0 ~limit:10 () in
      let event =
        match events with
        | [ event ] -> event
        | events ->
            fail
              (Printf.sprintf "expected one event, got %d"
                 (List.length events))
      in
      let open Yojson.Safe.Util in
      let replacement = "\xEF\xBF\xBD" in
      check string "payload repaired on read" ("bad" ^ replacement ^ "payload")
        (event.payload |> member "content" |> to_string);
      let stats_after_first = Safe_ops.persistence_utf8_repair_stats () in
      check int "file repair counted once" 1 stats_after_first.repaired_reads;
      check bool "backing file rewritten valid" true
        (String.is_valid_utf_8 (Fs_compat.load_file event_path));
      ignore (Activity_graph.list_events config ~after_seq:0 ~limit:10 ());
      let stats_after_second = Safe_ops.persistence_utf8_repair_stats () in
      check int "second read does not repair again" 1
        stats_after_second.repaired_reads)

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
           ~actor:(Activity_graph.entity ~kind:"agent" "mission-agent")
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

(* RFC-0323 G-3: approve-produced Done must complete the task in the graph
   projection exactly like task.done — node status, the ASSIGNEE's works_on
   edge (the event actor is the verifier), and the task span. *)
let test_task_approved_completes_graph_and_span () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"task.claimed"
           ~actor:(Activity_graph.entity ~kind:"agent" "worker-a")
           ~subject:(Activity_graph.entity ~kind:"task" "task-901")
           ~tags:[ "task"; "claim" ]
           ~payload:(`Assoc [ ("task_id", `String "task-901") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.started"
           ~actor:(Activity_graph.entity ~kind:"agent" "worker-a")
           ~subject:(Activity_graph.entity ~kind:"task" "task-901")
           ~tags:[ "task"; "start" ]
           ~payload:(`Assoc [ ("task_id", `String "task-901") ])
           ());
      ignore
        (Activity_graph.emit config ~kind:"task.approved"
           ~actor:(Activity_graph.entity ~kind:"agent" "verifier-b")
           ~subject:(Activity_graph.entity ~kind:"task" "task-901")
           ~tags:[ "task"; "approve" ]
           ~payload:
             (`Assoc
               [ ("task_id", `String "task-901");
                 ("assignee", `String "worker-a");
               ])
           ());
      let json =
        Activity_graph.graph_json config ~limit:20 ~timeline_limit:10 ()
      in
      let open Yojson.Safe.Util in
      let nodes = json |> member "nodes" |> to_list in
      (match
         List.find_opt
           (fun n -> String.equal (n |> member "id" |> to_string) "task:task-901")
           nodes
       with
      | Some n ->
          check string "task node completed" "done"
            (n |> member "status" |> to_string)
      | None -> Alcotest.fail "task node missing");
      let edges = json |> member "edges" |> to_list in
      (match
         List.find_opt
           (fun e ->
             String.equal (e |> member "source" |> to_string) "agent:worker-a"
             && String.equal (e |> member "target" |> to_string) "task:task-901"
             && String.equal (e |> member "kind" |> to_string) "works_on")
           edges
       with
      | Some e ->
          check bool "assignee works_on deactivated" false
            (e |> member "active" |> to_bool)
      | None -> Alcotest.fail "assignee works_on edge missing");
      let spans_json =
        Activity_graph.agent_spans_json config ~since_ms:0 ~limit:20 ()
      in
      let spans = spans_json |> member "spans" |> to_list in
      match
        List.find_opt
          (fun s -> String.equal (s |> member "label" |> to_string) "task-901")
          spans
      with
      | Some s ->
          check string "task span completed" "completed"
            (s |> member "status" |> to_string)
      | None -> Alcotest.fail "task span missing")

let test_parse_since_ms_supports_minutes () =
  check (option int) "5m parses" (Some (5 * 60 * 1000))
    (Server_activity_http.parse_since_ms "5m");
  check (option int) "1h still parses" (Some (3600 * 1000))
    (Server_activity_http.parse_since_ms "1h")

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
          test_case "events json derives IDE context" `Quick
            test_events_json_derives_ide_context;
          test_case "events json normalizes IDE context file paths" `Quick
            test_events_json_normalizes_ide_context_file_paths;
          test_case "events json omits unsafe IDE context file paths" `Quick
            test_events_json_omits_unsafe_ide_context_file_paths;
          test_case "events json ignores invalid derived PR number" `Quick
            test_events_json_ignores_invalid_derived_pr_number;
          test_case "events json exposes provenance and non-stale latest seq"
            `Quick test_events_json_exposes_provenance_and_non_stale_latest_seq;
          test_case "emit sanitizes invalid utf8 before persisting" `Quick
            test_emit_sanitizes_invalid_utf8_before_persisting;
          test_case "read self-heals historic invalid utf8 event file" `Quick
            test_read_self_heals_historic_invalid_utf8_event_file;
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
          test_case "task.approved completes graph and span" `Quick
            test_task_approved_completes_graph_and_span;
          test_case "parse_since_ms supports minutes" `Quick
            test_parse_since_ms_supports_minutes;
          test_case "span_status_opt None for unknown" `Quick
            test_span_status_of_string_opt_returns_none_for_unknown;
        ] );
    ]
