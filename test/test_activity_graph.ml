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

(* The store used to spell the YYYY-MM/DD.jsonl layout out for itself, and it
   read the clock once for the month directory and once more for the day file,
   so a write crossing midnight on the last of a month could land the new
   day's file under the old month's directory (#27143). The layout comes from
   Jsonl_writer now; this pins that it still does. *)
let test_day_file_follows_the_shared_layout () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"agent.joined"
           ~actor:(Activity_graph.entity ~kind:"agent" "claude")
           ~payload:(`Assoc [])
           ());
      let path = Activity_graph.For_testing.current_day_path config in
      check bool "the emitted day file exists" true (Sys.file_exists path);
      let expected =
        (Jsonl_writer.dated_path_now
           ~base_dir:
             (Filename.concat
                (Workspace_utils.masc_dir config)
                "activity-events"))
          .Jsonl_writer.path
      in
      check string "and Jsonl_writer names the same file" expected path;
      check bool
        "its directory is the one the writer would make"
        true
        (Sys.is_directory (Filename.dirname path)))
;;

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
          ~limit:10 ~keep:(fun _ -> true) ()
      in
      check int "two events" 2 (List.length events);
      check string "latest kind is task.created" "task.created"
        ((List.hd (List.rev events)).kind);
      let task_only =
        Activity_graph.list_events config
          ~kinds:[ "task.created" ] ~after_seq:0 ~limit:10 ~keep:(fun _ -> true) ()
      in
      check int "task filter" 1 (List.length task_only))

(* [limit] pages the events the caller asked for, so [keep] has to run before
   the cut. Filtering afterwards leaves no value of [limit] that means "this
   agent's newest N": the page fills with whatever the workspace was busy
   doing, and the quiet agent's events fall out of it entirely. The first
   check pins that behaviour; the second pins the filtered read. *)
let test_keep_runs_before_the_page_is_cut () =
  with_config (fun config ->
      let emit_for agent subject =
        ignore
          (Activity_graph.emit config ~kind:"keeper.turn_completed"
             ~actor:(Activity_graph.entity ~kind:"agent" agent)
             ~subject:(Activity_graph.entity ~kind:"log" subject)
             ~payload:(`Assoc [ ("keeper_name", `String agent) ])
             ())
      in
      emit_for "quiet" "quiet-1";
      emit_for "quiet" "quiet-2";
      for i = 1 to 20 do
        emit_for "busy" (Printf.sprintf "busy-%d" i)
      done;
      let is_quiet (e : Activity_graph.event) =
        match e.actor with
        | Some a -> String.equal a.id "quiet"
        | None -> false
      in
      let unfiltered =
        Activity_graph.list_events config ~after_seq:0 ~limit:5
          ~keep:(fun _ -> true) ()
      in
      check int "an unfiltered page of 5 holds none of the quiet agent's events" 0
        (List.length (List.filter is_quiet unfiltered));
      let filtered =
        Activity_graph.list_events config ~after_seq:0 ~limit:5 ~keep:is_quiet ()
      in
      check int "the filtered read returns every match under the limit" 2
        (List.length filtered);
      let bounded =
        Activity_graph.list_events config ~after_seq:0 ~limit:3
          ~keep:(fun e -> not (is_quiet e)) ()
      in
      check int "limit bounds the matches" 3 (List.length bounded))

let test_events_json_derives_ide_context () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
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
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
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
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
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
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
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
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-drive")
           ~tags:[ "file:C:\\workspace\\lib\\tag.ml:27" ]
           ~payload:(`Assoc [])
           ());
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-traversal")
           ~tags:[ "file:lib/../tag.ml:31" ]
           ~payload:(`Assoc [])
           ());
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
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
           ~actor:(Activity_graph.entity ~kind:"keeper" "alpha")
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
        Activity_graph.list_events config ~after_seq:0 ~limit:10 ~keep:(fun _ -> true) ()
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
         \"kind\":\"message.broadcast\",\
         \"payload\":{\"content\":\"bad\xffpayload\"},\"tags\":[]}\n"
      in
      Fs_compat.save_file event_path raw_line;
      check bool "fixture starts invalid" false
        (String.is_valid_utf_8 (Fs_compat.load_file event_path));
      let events = Activity_graph.list_events config ~after_seq:0 ~limit:10 ~keep:(fun _ -> true) () in
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
      ignore (Activity_graph.list_events config ~after_seq:0 ~limit:10 ~keep:(fun _ -> true) ());
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
      check bool "task node marked in progress" true
        (has_node "task:task-777" "in_progress");
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
            (s |> member "status" |> to_string);
          (* the span belongs to the assignee (worker-a) who did the work,
             not the verifier (verifier-b) whose task.approved closed it *)
          check string "task span attributed to assignee" "worker-a"
            (s |> member "agent" |> to_string)
      | None -> Alcotest.fail "task span missing")

(* ── P0-4 current-day incremental parse cache (masc perf root-cause
   report 2026-07-15, item (1)) ──────────────────────────────────── *)

let emit_n config n =
  for i = 1 to n do
    ignore
      (Activity_graph.emit config ~kind:"message.broadcast"
         ~actor:(Activity_graph.entity ~kind:"agent" "claude")
         ~payload:(`Assoc [ ("seq_hint", `Int i) ])
         ())
  done

(* Strips the wall-clock [generated_at_iso] field so two [json_response]
   calls made moments apart can be compared for structural equality. *)
let strip_generated_at_iso json =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (k, v) -> if String.equal k "generated_at_iso" then (k, `Null) else (k, v))
         fields)
  | other -> other

(* The gauge exists so an operator reads the cache instead of estimating it
   from RSS, so what has to hold is that the number follows the cache. A
   fixture day file from the past is what puts anything in the past-day cache
   at all: today's file belongs to the current-day cache. *)
let write_past_day_file config ~lines =
  let root = Filename.concat (Workspace_utils.masc_dir config) Activity_graph.store_dirname in
  let dir = Filename.concat root "2020-01" in
  let rec mkdir_p path =
    if not (Sys.file_exists path)
    then (
      mkdir_p (Filename.dirname path);
      try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir;
  let path = Filename.concat dir "02.jsonl" in
  let oc = open_out path in
  for i = 1 to lines do
    Printf.fprintf oc
      {|{"seq":%d,"ts_ms":1577923200000,"ts_iso":"2020-01-02T00:00:00Z","workspace_id":"default","kind":"test.fixture","actor":{"kind":"agent","id":"fixture"},"subject":{"kind":"tool","id":"fixture"},"payload":{}}|}
      i;
    output_char oc '\n'
  done;
  close_out oc;
  path
;;

let test_cache_stats_follow_the_cache () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_past_day_cache_for_testing ();
      let empty = Activity_graph.cache_stats () in
      check int "a cleared cache holds no files" 0 empty.Activity_graph.past_day_files;
      check int "and no records" 0 empty.Activity_graph.past_day_records;
      let _ = write_past_day_file config ~lines:7 in
      (* Reading is what populates it; the stats are a read, not a trigger. *)
      ignore
        (Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) ());
      let warm = Activity_graph.cache_stats () in
      check int "the past day file is held" 1 warm.Activity_graph.past_day_files;
      check int "and its records are counted" 7 warm.Activity_graph.past_day_records;
      Activity_graph.For_testing.reset_past_day_cache_for_testing ();
      let cleared = Activity_graph.cache_stats () in
      check int "clearing the cache clears the count" 0 cleared.Activity_graph.past_day_files)
;;

let test_current_day_cache_rebuilds_once_per_fingerprint () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 10;
      let first = Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) () in
      check int "first read sees 10 events" 10 (List.length first);
      check int "cold miss builds once" 1
        (Activity_graph.For_testing.current_day_rebuild_count ());
      emit_n config 5;
      let second = Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) () in
      check int "second read sees all 15 events" 15 (List.length second);
      check int "changed fingerprint rebuilds once" 2
        (Activity_graph.For_testing.current_day_rebuild_count ());
      ignore
        (Activity_graph.list_events config ~after_seq:0 ~limit:100
           ~keep:(fun _ -> true) ());
      check int "unchanged fingerprint reuses cache" 2
        (Activity_graph.For_testing.current_day_rebuild_count ()))

(* The aggregate is keyed on every file including today's, and today's grows
   on nearly every tick, so an append misses it. What must NOT happen on that
   miss is re-sorting the whole retained history: the past files did not move.
   On the live store 2026-08-29 that history was 440,068 events against 6,072
   in the current day, and every miss re-sorted all of them for a page of
   500. *)
let test_append_reuses_the_past_day_merge () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_past_day_cache_for_testing ();
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      let past_lines = write_past_day_file config ~lines:5 in
      ignore past_lines;
      emit_n config 3;
      let first =
        Activity_graph.list_events config ~after_seq:0 ~limit:100
          ~keep:(fun _ -> true) ()
      in
      check int "first read sees both days" 8 (List.length first);
      check int "the past merge is built once" 1
        (Activity_graph.For_testing.past_merged_rebuild_count ());
      emit_n config 2;
      let second =
        Activity_graph.list_events config ~after_seq:0 ~limit:100
          ~keep:(fun _ -> true) ()
      in
      check int "the append is visible" 10 (List.length second);
      check bool "the aggregate was rebuilt" true
        (Activity_graph.For_testing.all_events_rebuild_count () >= 2);
      check int "but the past merge was not" 1
        (Activity_graph.For_testing.past_merged_rebuild_count ());
      let seqs = List.map (fun (e : Activity_graph.event) -> e.seq) second in
      check (list int) "and the merge stays seq-ordered"
        (List.sort Int.compare seqs) seqs)
;;

(* The reuse is keyed on the past files' own signature, so a new past file
   has to rebuild it -- otherwise the split would serve a stale history. *)
let test_a_new_past_file_rebuilds_the_merge () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_past_day_cache_for_testing ();
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 2;
      ignore
        (Activity_graph.list_events config ~after_seq:0 ~limit:100
           ~keep:(fun _ -> true) ());
      let before = Activity_graph.For_testing.past_merged_rebuild_count () in
      ignore (write_past_day_file config ~lines:4);
      let after_write =
        Activity_graph.list_events config ~after_seq:0 ~limit:100
          ~keep:(fun _ -> true) ()
      in
      check int "the new past file is visible" 6 (List.length after_write);
      check bool "and the past merge was rebuilt for it" true
        (Activity_graph.For_testing.past_merged_rebuild_count () > before))
;;

let test_default_projections_share_unchanged_event_aggregate () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 10;
      ignore (Activity_graph.json_response config ~after_seq:0 ~limit:1000 ());
      ignore (Activity_graph.graph_json config ~limit:500 ~timeline_limit:80 ());
      ignore (Activity_graph.agent_spans_json config ~limit:500 ());
      check int "three unchanged projections share one aggregate rebuild" 1
        (Activity_graph.For_testing.all_events_rebuild_count ());
      emit_n config 1;
      ignore (Activity_graph.json_response config ~after_seq:0 ~limit:1000 ());
      check int "append invalidates aggregate signature" 2
        (Activity_graph.For_testing.all_events_rebuild_count ()))

let test_same_size_rewrite_invalidates_current_day_cache () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 1;
      ignore
        (Activity_graph.list_events config ~after_seq:0 ~limit:100
           ~keep:(fun _ -> true) ());
      let path = Activity_graph.For_testing.current_day_path config in
      let content = Fs_compat.load_file path in
      let needle = "\"seq_hint\":1" in
      let rec find i =
        if i + String.length needle > String.length content
        then Alcotest.fail "fixture payload marker missing"
        else if String.sub content i (String.length needle) = needle
        then i
        else find (i + 1)
      in
      let bytes = Bytes.of_string content in
      Bytes.set bytes (find 0 + String.length needle - 1) '9';
      Fs_compat.save_file path (Bytes.to_string bytes);
      let rewritten =
        Activity_graph.list_events config ~after_seq:0 ~limit:100
          ~keep:(fun _ -> true) ()
      in
      match rewritten with
      | [ event ] ->
        check int "same-size rewrite is reparsed" 9
          (event.Activity_graph.payload
           |> Yojson.Safe.Util.member "seq_hint"
           |> Yojson.Safe.Util.to_int)
      | events -> failf "expected one rewritten event, got %d" (List.length events))

let test_truncate_regrow_is_not_treated_as_append () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 1;
      ignore
        (Activity_graph.list_events config ~after_seq:0 ~limit:100
           ~keep:(fun _ -> true) ());
      let path = Activity_graph.For_testing.current_day_path config in
      let raw_line seq =
        Printf.sprintf
          "{\"seq\":%d,\"ts_ms\":%d,\"ts_iso\":\"2026-01-01T00:00:00Z\",\
           \"kind\":\"message.broadcast\",\"payload\":{},\"tags\":[]}\n"
          seq seq
      in
      Fs_compat.save_file path (raw_line 7 ^ raw_line 8);
      let rewritten =
        Activity_graph.list_events config ~after_seq:0 ~limit:100
          ~keep:(fun _ -> true) ()
      in
      check (list int) "replacement rows only" [ 7; 8 ]
        (List.map (fun event -> event.Activity_graph.seq) rewritten))

let test_aggregate_cache_retains_multiple_workspaces () =
  with_config (fun first ->
      with_config (fun second ->
        Activity_graph.For_testing.reset_current_day_cache_for_testing ();
        emit_n first 1;
        emit_n second 1;
        let read config =
          ignore
            (Activity_graph.list_events config ~after_seq:0 ~limit:100
               ~keep:(fun _ -> true) ())
        in
        read first;
        read second;
        check int "two roots each build once" 2
          (Activity_graph.For_testing.all_events_rebuild_count ());
        read first;
        check int "second root does not evict first" 2
          (Activity_graph.For_testing.all_events_rebuild_count ())))

let test_workspace_parse_caches_do_not_evict_each_other () =
  with_config (fun first ->
      with_config (fun second ->
        Activity_graph.For_testing.reset_current_day_cache_for_testing ();
        emit_n first 3;
        emit_n second 3;
        let read config =
          ignore
            (Activity_graph.list_events config ~after_seq:0 ~limit:100
               ~keep:(fun _ -> true) ())
        in
        read first;
        read second;
        read first;
        check int "first workspace parse cache survives second root" 2
          (Activity_graph.For_testing.current_day_rebuild_count ())))

let test_workspace_aggregate_cache_uses_lru_at_capacity () =
  Activity_graph.For_testing.reset_current_day_cache_for_testing ();
  for i = 0 to 15 do
    Activity_graph.For_testing.touch_workspace_cache (Printf.sprintf "root-%02d" i)
  done;
  Activity_graph.For_testing.touch_workspace_cache "root-00";
  Activity_graph.For_testing.touch_workspace_cache "root-16";
  check int "cache stays bounded" 16
    (Activity_graph.For_testing.workspace_cache_count ());
  check bool "recent root retained" true
    (Activity_graph.For_testing.workspace_cache_mem "root-00");
  check bool "least recently used root evicted" false
    (Activity_graph.For_testing.workspace_cache_mem "root-01");
  check bool "new root admitted" true
    (Activity_graph.For_testing.workspace_cache_mem "root-16")

let test_current_day_cache_matches_uncached_golden () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 4;
      ignore (Activity_graph.json_response config ~after_seq:0 ~limit:100 ());
      (* Grow behind the now-warm cache so the next read exercises the
         incremental delta-fold path, not a cold full parse. *)
      emit_n config 3;
      let incremental =
        Activity_graph.json_response config ~after_seq:0 ~limit:100 ()
        |> strip_generated_at_iso
      in
      (* Force the reference path: an empty cache means the very next
         read is a full, repair-aware [parse_events_from_file] call. *)
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      let uncached =
        Activity_graph.json_response config ~after_seq:0 ~limit:100 ()
        |> strip_generated_at_iso
      in
      check string "incremental path output matches full-reparse reference"
        (Yojson.Safe.to_string uncached) (Yojson.Safe.to_string incremental))

let test_current_day_cache_rescans_from_zero_on_truncation () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_current_day_cache_for_testing ();
      emit_n config 6;
      let baseline = Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) () in
      check int "baseline has 6 events" 6 (List.length baseline);
      (* Simulate rotation/truncation: rewrite the current-day file
         smaller than the cached boundary. *)
      let path = Activity_graph.For_testing.current_day_path config in
      let raw_line seq =
        Printf.sprintf
          "{\"seq\":%d,\"ts_ms\":%d,\"ts_iso\":\"2026-01-01T00:00:00Z\",\
           \"kind\":\"message.broadcast\",\
           \"payload\":{},\"tags\":[]}\n"
          seq seq
      in
      Fs_compat.save_file path (raw_line 1 ^ raw_line 2);
      let after_truncate = Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) () in
      check int "truncated file rescanned from zero, not merged with stale cache"
        2 (List.length after_truncate))

let test_past_day_cache_evicts_entries_for_deleted_files () =
  with_config (fun config ->
      Activity_graph.For_testing.reset_past_day_cache_for_testing ();
      let baseline_count = Activity_graph.For_testing.past_day_cache_entry_count () in
      let root = Filename.concat (Workspace_utils.masc_dir config) "activity-events" in
      let month_dir = Filename.concat root "2000-01" in
      Unix.mkdir root 0o755;
      Unix.mkdir month_dir 0o755;
      let day_path = Filename.concat month_dir "01.jsonl" in
      Fs_compat.save_file day_path
        "{\"seq\":1,\"ts_ms\":1,\"ts_iso\":\"2000-01-01T00:00:00Z\",\
         \"kind\":\"message.broadcast\",\
         \"payload\":{},\"tags\":[]}\n";
      ignore (Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) ());
      check bool "past-day file is now cached" true
        (Activity_graph.For_testing.past_day_cache_entry_count () > baseline_count);
      Sys.remove day_path;
      Unix.rmdir month_dir;
      ignore (Activity_graph.list_events config ~after_seq:0 ~limit:100 ~keep:(fun _ -> true) ());
      check int "cache entry evicted once the backing file is gone"
        baseline_count (Activity_graph.For_testing.past_day_cache_entry_count ()))

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


(* Node accumulators are values, not cells. A record read out of the table
   before a later event keeps what it was read with, while the table itself
   advances. Against the previous in-place form both checks on [first] would
   fail, because [first] and the table entry were the same physical record. *)
let test_reducer_replaces_node_entries_instead_of_writing_through () =
  let nodes = Hashtbl.create 8 in
  let edges = Hashtbl.create 8 in
  let event seq ts_iso : Activity_graph_types.event =
    {
      seq;
      ts_ms = seq * 1000;
      ts_iso;
      kind = "task.assigned";
      actor = Some { kind = "agent"; id = "a1" };
      subject = Some { kind = "task"; id = "t1" };
      payload = `Assoc [];
      tags = [];
    }
  in
  Activity_graph_reducer.reduce_event ~nodes ~edges
    (event 1 "2026-01-01T00:00:00Z");
  let first : Activity_graph_reducer.node_acc =
    match Hashtbl.find_opt nodes "agent:a1" with
    | Some node -> node
    | None -> fail "actor node missing after the first event"
  in
  check int "first read sees one hit" 1 first.weight;
  Activity_graph_reducer.reduce_event ~nodes ~edges
    (event 2 "2026-01-02T00:00:00Z");
  check int "the earlier record keeps its weight" 1 first.weight;
  check string "the earlier record keeps its timestamp" "2026-01-01T00:00:00Z"
    first.last_event_at;
  let second : Activity_graph_reducer.node_acc =
    match Hashtbl.find_opt nodes "agent:a1" with
    | Some node -> node
    | None -> fail "actor node missing after the second event"
  in
  check int "the table advances the weight" 2 second.weight;
  check string "the table advances the timestamp" "2026-01-02T00:00:00Z"
    second.last_event_at
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Activity Graph"
    [
      ( "core",
        [
          test_case "day file follows the shared layout" `Quick
            test_day_file_follows_the_shared_layout;
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
      ( "current_day_cache",
        [
          test_case "current-day cache rebuilds once per fingerprint" `Quick
            test_current_day_cache_rebuilds_once_per_fingerprint;
          Alcotest.test_case "unchanged projections share sorted aggregate"
            `Quick test_default_projections_share_unchanged_event_aggregate;
          test_case "append reuses the past-day merge" `Quick
            test_append_reuses_the_past_day_merge;
          test_case "a new past file rebuilds the merge" `Quick
            test_a_new_past_file_rebuilds_the_merge;
          Alcotest.test_case "same-size rewrite invalidates cache" `Quick
            test_same_size_rewrite_invalidates_current_day_cache;
          Alcotest.test_case "truncate-regrow is not append" `Quick
            test_truncate_regrow_is_not_treated_as_append;
          Alcotest.test_case "aggregate cache retains multiple workspaces"
            `Quick test_aggregate_cache_retains_multiple_workspaces;
          Alcotest.test_case "workspace parse caches are isolated" `Quick
            test_workspace_parse_caches_do_not_evict_each_other;
          Alcotest.test_case "workspace aggregate cache uses bounded lru" `Quick
            test_workspace_aggregate_cache_uses_lru_at_capacity;
          test_case "cache_stats follow the cache" `Quick
            test_cache_stats_follow_the_cache;
          test_case "incremental path output matches full-reparse reference"
            `Quick test_current_day_cache_matches_uncached_golden;
          test_case "truncated file rescans from zero" `Quick
            test_current_day_cache_rescans_from_zero_on_truncation;
          test_case "past-day cache evicts entries for deleted files" `Quick
            test_past_day_cache_evicts_entries_for_deleted_files;
          test_case "keep runs before the page is cut" `Quick
            test_keep_runs_before_the_page_is_cut;
        ] );
      ( "reducer",
        [
          test_case "a later event replaces the node entry rather than writing through"
            `Quick test_reducer_replaces_node_entries_instead_of_writing_through;
        ] );
    ]
