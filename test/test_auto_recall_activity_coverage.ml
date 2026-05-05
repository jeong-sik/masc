module Types = Masc_domain

(** Coverage tests for auto_recall (pure functions) and activity_feed (JSON roundtrip).
    Also covers filesystem-backed activity_feed read-path regressions. *)

open Alcotest
open Masc_mcp

(* ============================================================
   1. Auto_recall — estimate_tokens
   ============================================================ *)

let test_estimate_tokens_empty () =
  let t = Auto_recall.estimate_tokens "" in
  (* (0+3)/4 = 0 (integer division) *)
  check int "empty" 0 t

let test_estimate_tokens_short () =
  let t = Auto_recall.estimate_tokens "hello" in
  (* (5+3)/4 = 2 *)
  check int "short" 2 t

let test_estimate_tokens_long () =
  let text = String.make 400 'x' in
  let t = Auto_recall.estimate_tokens text in
  (* (400+3)/4 = 100 *)
  check int "long" 100 (t - 1 + 1)  (* approximately 100 *)

(* ============================================================
   2. Auto_recall — default_config
   ============================================================ *)

let test_default_config () =
  let c = Auto_recall.default_config in
  check bool "enabled" true c.enabled;
  check int "max_tokens" 2000 c.max_tokens;
  check int "max_broadcasts" 10 c.max_broadcasts;
  check int "sources" 2 (List.length c.sources)

(* ============================================================
   3. Auto_recall — make_config
   ============================================================ *)

let test_make_config_defaults () =
  let c = Auto_recall.make_config () in
  check bool "enabled" true c.enabled;
  check int "max_tokens" 2000 c.max_tokens

let test_make_config_custom () =
  let c = Auto_recall.make_config ~enabled:false ~max_tokens:500 ~max_broadcasts:5
      ~cache_tags:["tag1"; "tag2"] () in
  check bool "disabled" false c.enabled;
  check int "max_tokens" 500 c.max_tokens;
  check int "max_broadcasts" 5 c.max_broadcasts;
  check int "tags" 2 (List.length c.cache_tags)

(* ============================================================
   4. Auto_recall — extract_query_hints
   ============================================================ *)

let test_extract_hints_basic () =
  let hints = Auto_recall.extract_query_hints "search for large files" in
  (* filters common words and words <= 2 chars *)
  check bool "non-empty" true (List.length hints > 0);
  check bool "has search" true (List.mem "search" hints);
  check bool "no for" false (List.mem "for" hints)

let test_extract_hints_empty () =
  let hints = Auto_recall.extract_query_hints "" in
  check int "empty" 0 (List.length hints)

let test_extract_hints_common_words () =
  let hints = Auto_recall.extract_query_hints "the a an is are was were be to of and in for" in
  check int "all filtered" 0 (List.length hints)

let test_extract_hints_short_words () =
  let hints = Auto_recall.extract_query_hints "a b c" in
  check int "too short" 0 (List.length hints)

(* ============================================================
   5. Auto_recall — content_matches_query
   ============================================================ *)

let test_content_matches_empty_query () =
  let r = Auto_recall.content_matches_query "some content" "" in
  check bool "empty query matches" true r

let test_content_matches_positive () =
  let r = Auto_recall.content_matches_query "This is about OCaml programming" "OCaml programming" in
  check bool "matches" true r

let test_content_matches_negative () =
  let r = Auto_recall.content_matches_query "This is about Python" "OCaml Haskell" in
  check bool "no match" false r

let test_content_matches_case_insensitive () =
  let r = Auto_recall.content_matches_query "HELLO WORLD" "hello" in
  check bool "case insensitive" true r

let test_content_matches_short_hints_ignored () =
  (* All hints are too short (<3 chars) *)
  let r = Auto_recall.content_matches_query "some content" "a b c" in
  check bool "short hints" false r

(* ============================================================
   6. Auto_recall — format_for_injection
   ============================================================ *)

let test_format_empty () =
  let result : Auto_recall.recall_result = { items = []; total_tokens = 0; truncated = false } in
  let s = Auto_recall.format_for_injection result in
  check string "empty" "" s

let test_format_with_items () =
  let item1 : Auto_recall.recall_item = {
    source = Recent_broadcasts; content = "hello from agent";
    relevance = 0.8; metadata = `Null
  } in
  let item2 : Auto_recall.recall_item = {
    source = Masc_cache; content = "cached data";
    relevance = 0.5; metadata = `Null
  } in
  let result : Auto_recall.recall_result = {
    items = [item1; item2]; total_tokens = 50; truncated = false
  } in
  let s = Auto_recall.format_for_injection result in
  check bool "has header" true (String.length s > 0);
  check bool "has broadcast" true (try let _ = Str.search_forward (Str.regexp_string "broadcast") s 0 in true with Not_found -> false);
  check bool "has cache" true (try let _ = Str.search_forward (Str.regexp_string "cache") s 0 in true with Not_found -> false)

let test_format_truncated () =
  let item : Auto_recall.recall_item = {
    source = File_context; content = "file content";
    relevance = 0.6; metadata = `Null
  } in
  let result : Auto_recall.recall_result = {
    items = [item]; total_tokens = 100; truncated = true
  } in
  let s = Auto_recall.format_for_injection result in
  check bool "has truncated" true (try let _ = Str.search_forward (Str.regexp_string "truncated") s 0 in true with Not_found -> false)

(* ============================================================
   7. Auto_recall — to_json
   ============================================================ *)

let test_to_json () =
  let item : Auto_recall.recall_item = {
    source = Recent_broadcasts; content = "hello";
    relevance = 0.8; metadata = `Assoc [("key", `String "val")]
  } in
  let result : Auto_recall.recall_result = {
    items = [item]; total_tokens = 10; truncated = false
  } in
  let j = Auto_recall.to_json result in
  match j with
  | `Assoc fields ->
    check bool "has items" true (List.mem_assoc "items" fields);
    check bool "has total_tokens" true (List.mem_assoc "total_tokens" fields);
    check bool "has truncated" true (List.mem_assoc "truncated" fields)
  | _ -> fail "not Assoc"

let test_to_json_all_sources () =
  let sources = [Auto_recall.Masc_cache; Recent_broadcasts; File_context] in
  List.iter (fun source ->
    let item : Auto_recall.recall_item = { source; content = "c"; relevance = 0.5; metadata = `Null } in
    let result : Auto_recall.recall_result = { items = [item]; total_tokens = 1; truncated = false } in
    let j = Auto_recall.to_json result in
    let s = Yojson.Safe.to_string j in
    check bool "valid json" true (String.length s > 10)
  ) sources

(* ============================================================
   8. Activity_feed — activity_item_to_json / activity_item_of_json roundtrip
   ============================================================ *)

let test_activity_item_roundtrip () =
  let item : Activity_feed.activity_item = {
    id = "act-001";
    kind = "task";
    agent_name = "agent1";
    summary = "Task completed";
    detail_json = `Assoc [("status", `String "done")];
    created_at = 1700000000.0;
  } in
  let json = Activity_feed.activity_item_to_json item in
  match Activity_feed.activity_item_of_json json with
  | Some item2 ->
    check string "id" "act-001" item2.id;
    check string "kind" "task" item2.kind;
    check string "agent" "agent1" item2.agent_name;
    check string "summary" "Task completed" item2.summary;
    check (float 0.01) "created_at" 1700000000.0 item2.created_at
  | None -> fail "roundtrip failed"

let test_activity_item_empty_id () =
  let json = `Assoc [
    ("id", `String "");
    ("kind", `String "task");
    ("agent_name", `String "a");
    ("summary", `String "s");
    ("created_at", `Float 1.0);
  ] in
  check (option reject) "empty id" None (Activity_feed.activity_item_of_json json)

let test_activity_item_missing_detail () =
  let json = `Assoc [
    ("id", `String "x");
    ("kind", `String "task");
    ("agent_name", `String "a");
    ("summary", `String "s");
    ("created_at", `Float 1.0);
  ] in
  match Activity_feed.activity_item_of_json json with
  | Some item -> check string "id" "x" item.id
  | None -> fail "should parse without detail_json"

let test_activity_item_malformed () =
  let json = `String "not an object" in
  check (option reject) "malformed" None (Activity_feed.activity_item_of_json json)

let test_activity_item_defaults () =
  let json = `Assoc [
    ("id", `String "x");
  ] in
  match Activity_feed.activity_item_of_json json with
  | Some item ->
    check string "kind default" "" item.kind;
    check string "agent default" "" item.agent_name;
    check string "summary default" "" item.summary;
    check (float 0.01) "created_at default" 0.0 item.created_at
  | None -> fail "should parse with defaults"

(* ============================================================
   9. Activity_feed — filesystem-backed read paths
   ============================================================ *)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Sys.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let write_file path content =
  Fs_compat.save_file path content

let capture_stderr f =
  let pipe_read, pipe_write = Unix.pipe () in
  let saved_stderr = Unix.dup Unix.stderr in
  Unix.dup2 pipe_write Unix.stderr;
  Unix.close pipe_write;
  (try f () with _ -> ());
  flush stderr;
  Unix.dup2 saved_stderr Unix.stderr;
  Unix.close saved_stderr;
  Unix.set_nonblock pipe_read;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 256 in
  let rec read_all () =
    match Unix.read pipe_read tmp 0 256 with
    | 0 -> ()
    | n -> Buffer.add_subbytes buf tmp 0 n; read_all ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception _ -> ()
  in
  read_all ();
  Unix.close pipe_read;
  Buffer.contents buf

let str_contains haystack needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let found = ref false in
    let i = ref 0 in
    while !i <= hl - nl && not !found do
      if String.sub haystack !i nl = needle then found := true;
      incr i
    done;
    !found
  end

let test_recent_activity_skips_malformed_jsonl_lines () =
  with_temp_dir "activity-feed-jsonl" @@ fun base_path ->
  let config = Coord.default_config base_path in
  let masc_dir = Coord.masc_dir config in
  Fs_compat.mkdir_p masc_dir;
  let board_posts_path = Filename.concat masc_dir "board_posts.jsonl" in
  write_file board_posts_path
    (String.concat "\n"
       [
         Yojson.Safe.to_string
           (`Assoc
             [
               ("id", `String "post-1");
               ("author", `String "alice");
               ("title", `String "Hello");
               ("content", `String "body");
               ("created_at", `Float 123.0);
             ]);
         "not-json";
       ] ^ "\n");
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "valid board post survives" 1 (List.length items);
  match items with
  | [item] ->
      check string "summary preserved" "Posted: Hello" item.summary;
      check (float 0.01) "timestamp preserved" 123.0 item.created_at
  | _ -> fail "expected one activity item"

let test_recent_activity_accepts_iso_string_created_at_for_board_posts () =
  with_temp_dir "activity-feed-jsonl-iso" @@ fun base_path ->
  let config = Coord.default_config base_path in
  let masc_dir = Coord.masc_dir config in
  Fs_compat.mkdir_p masc_dir;
  let board_posts_path = Filename.concat masc_dir "board_posts.jsonl" in
  let iso_created_at = "2026-04-22T13:01:48Z" in
  write_file board_posts_path
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("id", `String "post-iso");
           ("author", `String "alice");
           ("title", `String "Hello");
           ("content", `String "body");
           ("created_at", `String iso_created_at);
         ]) ^ "\n");
  let stderr_output =
    capture_stderr (fun () ->
        ignore (Activity_feed.recent_activity config ~limit:10 ()))
  in
  check bool "does not warn for ISO created_at" false
    (str_contains stderr_output "board post missing/invalid created_at");
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "valid ISO board post survives" 1 (List.length items);
  match items, Types.parse_iso8601_opt iso_created_at with
  | [item], Some expected_ts ->
      check string "summary preserved" "Posted: Hello" item.summary;
      check (float 0.01) "ISO timestamp preserved" expected_ts item.created_at
  | [ _ ], None -> fail "expected ISO fixture to parse"
  | _ -> fail "expected one activity item"

let test_recent_activity_skips_bad_task_file () =
  with_temp_dir "activity-feed-task" @@ fun base_path ->
  let config = Coord.default_config base_path in
  let masc_dir = Coord.masc_dir config in
  let tasks_dir = Filename.concat masc_dir "tasks" in
  Fs_compat.mkdir_p tasks_dir;
  write_file (Filename.concat tasks_dir "good.json")
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("id", `String "task-1");
           ("status", `String "done");
           ("assignee", `String "bob");
           ("title", `String "Write tests");
           ("created_at", `String "2026-04-10T01:02:03");
         ]));
  write_file (Filename.concat tasks_dir "bad.json") "{\"id\":";
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "malformed task file skipped" 1 (List.length items);
  match items with
  | [item] ->
      check string "task summary preserved" "Task task-1: Write tests (done)"
        item.summary
  | _ -> fail "expected one task activity item"

let test_recent_activity_falls_back_from_bad_task_timestamp () =
  with_temp_dir "activity-feed-ts" @@ fun base_path ->
  let config = Coord.default_config base_path in
  let masc_dir = Coord.masc_dir config in
  let tasks_dir = Filename.concat masc_dir "tasks" in
  Fs_compat.mkdir_p tasks_dir;
  write_file (Filename.concat tasks_dir "task.json")
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("id", `String "task-2");
           ("status", `String "running");
           ("assignee", `String "carol");
           ("title", `String "Investigate");
           ("created_at", `String "not-a-timestamp");
         ]));
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "task still included" 1 (List.length items);
  match items with
  | [item] ->
      check (float 0.01) "timestamp falls back to epoch 0.0" 0.0
        item.created_at
  | _ -> fail "expected one task activity item"

let test_recent_activity_ignores_backlog_json_without_timestamp_warning () =
  with_temp_dir "activity-feed-backlog" @@ fun base_path ->
  let config = Coord.default_config base_path in
  let masc_dir = Coord.masc_dir config in
  let tasks_dir = Filename.concat masc_dir "tasks" in
  Fs_compat.mkdir_p tasks_dir;
  write_file (Filename.concat tasks_dir "backlog.json")
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("tasks", `List []);
           ("last_updated", `String "2026-04-22T13:01:48Z");
           ("version", `Int 7);
         ]));
  let output =
    capture_stderr (fun () ->
        ignore (Activity_feed.recent_activity config ~limit:10 ()))
  in
  check bool "backlog timestamp fallback warning suppressed" false
    (str_contains output "task activity timestamp parse fallback");
  let items = Activity_feed.recent_activity config ~limit:10 () in
  check int "backlog does not become an activity item" 0 (List.length items)

(* ============================================================
   Runner
   ============================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "auto_recall_activity_coverage" [
    "estimate_tokens", [
      test_case "empty" `Quick test_estimate_tokens_empty;
      test_case "short" `Quick test_estimate_tokens_short;
      test_case "long" `Quick test_estimate_tokens_long;
    ];
    "default_config", [
      test_case "defaults" `Quick test_default_config;
    ];
    "make_config", [
      test_case "defaults" `Quick test_make_config_defaults;
      test_case "custom" `Quick test_make_config_custom;
    ];
    "extract_query_hints", [
      test_case "basic" `Quick test_extract_hints_basic;
      test_case "empty" `Quick test_extract_hints_empty;
      test_case "common words" `Quick test_extract_hints_common_words;
      test_case "short words" `Quick test_extract_hints_short_words;
    ];
    "content_matches_query", [
      test_case "empty query" `Quick test_content_matches_empty_query;
      test_case "positive" `Quick test_content_matches_positive;
      test_case "negative" `Quick test_content_matches_negative;
      test_case "case insensitive" `Quick test_content_matches_case_insensitive;
      test_case "short hints" `Quick test_content_matches_short_hints_ignored;
    ];
    "format_for_injection", [
      test_case "empty" `Quick test_format_empty;
      test_case "with items" `Quick test_format_with_items;
      test_case "truncated" `Quick test_format_truncated;
    ];
    "to_json", [
      test_case "basic" `Quick test_to_json;
      test_case "all sources" `Quick test_to_json_all_sources;
    ];
    "activity_item", [
      test_case "roundtrip" `Quick test_activity_item_roundtrip;
      test_case "empty id" `Quick test_activity_item_empty_id;
      test_case "missing detail" `Quick test_activity_item_missing_detail;
      test_case "malformed" `Quick test_activity_item_malformed;
      test_case "defaults" `Quick test_activity_item_defaults;
    ];
    "activity_feed_fs", [
      test_case "skips malformed jsonl lines" `Quick
        test_recent_activity_skips_malformed_jsonl_lines;
      test_case "accepts ISO string created_at for board posts" `Quick
        test_recent_activity_accepts_iso_string_created_at_for_board_posts;
      test_case "skips bad task file" `Quick
        test_recent_activity_skips_bad_task_file;
      test_case "falls back from bad task timestamp" `Quick
        test_recent_activity_falls_back_from_bad_task_timestamp;
      test_case "ignores backlog json without timestamp warning" `Quick
        test_recent_activity_ignores_backlog_json_without_timestamp_warning;
    ];
  ]
