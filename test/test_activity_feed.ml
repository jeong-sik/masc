open Alcotest
open Masc

let test_activity_item_json_contract () =
  let item : Activity_feed.activity_item =
    { id = "act-001"
    ; kind = "task"
    ; agent_name = "agent1"
    ; summary = "Task completed"
    ; detail_json = `Assoc [ "status", `String "done" ]
    ; created_at = 1_700_000_000.0
    }
  in
  let expected =
    `Assoc
      [ "id", `String item.id
      ; "kind", `String item.kind
      ; "agent_name", `String item.agent_name
      ; "summary", `String item.summary
      ; "detail_json", item.detail_json
      ; "created_at", `Float item.created_at
      ]
  in
  check bool
    "activity API item wire shape"
    true
    (Yojson.Safe.equal expected (Activity_feed.activity_item_to_json item))
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Sys.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let write_file = Fs_compat.save_file

let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.seq
  | [] -> 0
;;

let feed_warnings_since seq =
  Log.Ring.recent ~limit:Log.Ring.capacity ~module_filter:"Feed" ~since_seq:seq ()
  |> List.filter (fun (entry : Log.Ring.entry) -> entry.level = Log.Warn)
;;

let test_recent_activity_skips_malformed_jsonl_lines () =
  with_temp_dir "activity-feed-jsonl" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let masc_dir = Workspace.masc_dir config in
  Fs_compat.mkdir_p masc_dir;
  let board_posts_path = Filename.concat masc_dir "board_posts.jsonl" in
  write_file
    board_posts_path
    (String.concat
       "\n"
       [ Yojson.Safe.to_string
           (`Assoc
             [ "id", `String "post-1"
             ; "author", `String "alice"
             ; "title", `String "Hello"
             ; "content", `String "body"
             ; "created_at", `Float 123.0
             ])
       ; "not-json"
       ]
     ^ "\n");
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "valid board post survives" 1 (List.length items);
  match items with
  | [ item ] ->
    check string "summary preserved" "Posted: Hello" item.summary;
    check (float 0.01) "timestamp preserved" 123.0 item.created_at
  | _ -> fail "expected one activity item"
;;

let test_recent_activity_accepts_iso_string_created_at_for_board_posts () =
  with_temp_dir "activity-feed-jsonl-iso" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let masc_dir = Workspace.masc_dir config in
  Fs_compat.mkdir_p masc_dir;
  let board_posts_path = Filename.concat masc_dir "board_posts.jsonl" in
  let iso_created_at = "2026-04-22T13:01:48Z" in
  write_file
    board_posts_path
    (Yojson.Safe.to_string
       (`Assoc
         [ "id", `String "post-iso"
         ; "author", `String "alice"
         ; "title", `String "Hello"
         ; "content", `String "body"
         ; "created_at", `String iso_created_at
         ])
     ^ "\n");
  let before_seq = latest_ring_seq () in
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "ISO created_at emits no warning" 0 (List.length (feed_warnings_since before_seq));
  check int "valid ISO board post survives" 1 (List.length items);
  match items, Masc_domain.parse_iso8601_opt iso_created_at with
  | [ item ], Some expected_ts ->
    check string "summary preserved" "Posted: Hello" item.summary;
    check (float 0.01) "ISO timestamp preserved" expected_ts item.created_at
  | [ _ ], None -> fail "expected ISO fixture to parse"
  | _ -> fail "expected one activity item"
;;

let test_recent_activity_skips_bad_task_file () =
  with_temp_dir "activity-feed-task" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let tasks_dir = Filename.concat (Workspace.masc_dir config) "tasks" in
  Fs_compat.mkdir_p tasks_dir;
  write_file
    (Filename.concat tasks_dir "good.json")
    (Yojson.Safe.to_string
       (`Assoc
         [ "id", `String "task-1"
         ; "status", `String "done"
         ; "assignee", `String "bob"
         ; "title", `String "Write tests"
         ; "created_at", `String "2026-04-10T01:02:03"
         ]));
  write_file (Filename.concat tasks_dir "bad.json") "{\"id\":";
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "malformed task file skipped" 1 (List.length items);
  match items with
  | [ item ] ->
    check string "task summary preserved" "Task task-1: Write tests (done)" item.summary
  | _ -> fail "expected one task activity item"
;;

let test_recent_activity_falls_back_from_bad_task_timestamp () =
  with_temp_dir "activity-feed-ts" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let tasks_dir = Filename.concat (Workspace.masc_dir config) "tasks" in
  Fs_compat.mkdir_p tasks_dir;
  write_file
    (Filename.concat tasks_dir "task.json")
    (Yojson.Safe.to_string
       (`Assoc
         [ "id", `String "task-2"
         ; "status", `String "running"
         ; "assignee", `String "carol"
         ; "title", `String "Investigate"
         ; "created_at", `String "not-a-timestamp"
         ]));
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "task still included" 1 (List.length items);
  match items with
  | [ item ] -> check (float 0.01) "timestamp falls back to epoch" 0.0 item.created_at
  | _ -> fail "expected one task activity item"
;;

let test_recent_activity_ignores_backlog_json_without_warning () =
  with_temp_dir "activity-feed-backlog" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let tasks_dir = Filename.concat (Workspace.masc_dir config) "tasks" in
  Fs_compat.mkdir_p tasks_dir;
  write_file
    (Filename.concat tasks_dir "backlog.json")
    (Yojson.Safe.to_string
       (`Assoc
         [ "tasks", `List []
         ; "last_updated", `String "2026-04-22T13:01:48Z"
         ; "version", `Int 7
         ]));
  let before_seq = latest_ring_seq () in
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "backlog emits no warning" 0 (List.length (feed_warnings_since before_seq));
  check int "backlog does not become an activity item" 0 (List.length items)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect
    ~finally:Fs_compat.clear_fs
    (fun () ->
      Eio_guard.enable ();
      run
        "activity_feed"
        [ ( "wire"
          , [ test_case "activity item JSON contract" `Quick test_activity_item_json_contract ] )
        ; ( "filesystem"
          , [ test_case
                "skips malformed jsonl lines"
                `Quick
                test_recent_activity_skips_malformed_jsonl_lines
            ; test_case
                "accepts ISO string created_at"
                `Quick
                test_recent_activity_accepts_iso_string_created_at_for_board_posts
            ; test_case "skips bad task file" `Quick test_recent_activity_skips_bad_task_file
            ; test_case
                "falls back from bad task timestamp"
                `Quick
                test_recent_activity_falls_back_from_bad_task_timestamp
            ; test_case
                "ignores backlog json without warning"
                `Quick
                test_recent_activity_ignores_backlog_json_without_warning
            ] )
        ])
;;
