(** Tests for IDE Bridge — event collection and pull request result parsing. *)

open Alcotest

let test_parse_pull_request_result_direct_json () =
  match
    Ide_bridge.parse_pull_request_result_from_output
      {|{"number":19872,"url":"https://github.com/jeong-sik/masc/pull/19872"}|}
  with
  | Some (number, url) ->
    check int "pr number" 19872 number;
    check string "pull request url" "https://github.com/jeong-sik/masc/pull/19872" url
  | None -> fail "expected Some"
;;

let test_parse_pull_request_result_wrapped_json () =
  let output =
    {|{"ok":true,"output":"{\"number\":123,\"url\":\"https://github.com/jeong-sik/masc/pull/123\"}","command_descriptor":{"kind":"gh_pr_create","title":"feat","base":"main","draft":false}}|}
  in
  match Ide_bridge.parse_pull_request_result_from_output output with
  | Some (number, url) ->
    check int "pr number" 123 number;
    check string "pull request url" "https://github.com/jeong-sik/masc/pull/123" url
  | None -> fail "expected Some"
;;

let test_parse_pull_request_result_prefers_html_url () =
  match
    Ide_bridge.parse_pull_request_result_from_output
      {|{"number":44,"url":"https://api.github.com/repos/owner/repo/pulls/44","html_url":"https://github.com/owner/repo/pull/44"}|}
  with
  | Some (number, url) ->
    check int "pr number" 44 number;
    check string "pull request url" "https://github.com/owner/repo/pull/44" url
  | None -> fail "expected Some"
;;

let test_parse_pull_request_result_ignores_raw_url () =
  check (option (pair int string)) "raw url ignored"
    None
    (Ide_bridge.parse_pull_request_result_from_output
       "https://github.com/jeong-sik/masc/pull/19872")
;;

let test_parse_pull_request_result_no_number () =
  check (option (pair int string)) "no number"
    None
    (Ide_bridge.parse_pull_request_result_from_output
       {|{"url":"https://github.com/owner/repo/pull/123"}|})
;;

let with_temp_dir f =
  let dir = Filename.temp_file "ide_bridge_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  (try f dir with exn ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" dir));
     raise exn);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" dir))
;;

let test_ingest_tool_event () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"fs_write"
      ~keeper_id:"keeper-alpha"
      ~turn_id:"turn-123"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:150
      ~summary:"Wrote 50 lines to test.ml"
      ~file_path:(Some "lib/test.ml")
      ~timestamp_ms:1717400000000L
      ();
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let tool_name = Yojson.Safe.Util.member "tool_name" json |> Yojson.Safe.Util.to_string in
    let keeper_id = Yojson.Safe.Util.member "keeper_id" json |> Yojson.Safe.Util.to_string in
    check string "tool_name" "fs_write" tool_name;
    check string "keeper_id" "keeper-alpha" keeper_id)
;;

let test_ingest_turn_event () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_turn_event
      ~base_path:base_dir
      ~turn_id:"turn-456"
      ~keeper_id:"keeper-beta"
      ~phase:"completed"
      ~model_used:(Some "claude-sonnet-4-6")
      ~tools_used:["fs_write"; "execute"]
      ~stop_reason:(Some "end_turn")
      ~duration_ms:(Some 5000)
      ~timestamp_ms:1717400000000L;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "turn_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let phase = Yojson.Safe.Util.member "phase" json |> Yojson.Safe.Util.to_string in
    check string "phase" "completed" phase)
;;

let test_ingest_multiple_events () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"fs_write"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"first"
      ~file_path:None
      ~timestamp_ms:1000L
      ();
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:200
      ~summary:"second"
      ~file_path:None
      ~timestamp_ms:2000L
      ();
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let count = ref 0 in
    (try while true do ignore (input_line ic); incr count done with End_of_file -> ());
    close_in ic;
    check int "two events" 2 !count)
;;

let json_string key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_string
;;

let json_intlit key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Int64.of_int i
  | `Intlit s -> Int64.of_string s
  | _ -> failwith ("expected int field " ^ key)
;;

let json_int key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_int
;;

let test_list_events_filters_keeper_and_pages () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t-old"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"old"
      ~file_path:None
      ~timestamp_ms:1000L
      ();
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"read_file"
      ~keeper_id:"k2"
      ~turn_id:"t-other"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"other"
      ~file_path:None
      ~timestamp_ms:3000L
      ();
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"write_file"
      ~keeper_id:"k1"
      ~turn_id:"t-new"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"new"
      ~file_path:None
      ~timestamp_ms:2000L
      ();
    let events =
      Ide_bridge.list_events
        ~base_path:base_dir
        ~kind:Ide_bridge.Tool
        ~keeper_id:"k1"
        ~limit:1
        ()
    in
    match events with
    | [ event ] ->
      check string "keeper filter" "k1" (json_string "keeper_id" event);
      check string "newest event" "t-new" (json_string "turn_id" event)
    | _ -> fail "expected one paged event")
;;

let test_list_events_merges_kinds_newest_first () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t-tool"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"tool"
      ~file_path:None
      ~timestamp_ms:1000L
      ();
    Ide_bridge.ingest_pr_event
      ~base_path:base_dir
      ~pr_number:42
      ~pull_request_url:"https://github.com/owner/repo/pull/42"
      ~pr_title:"feat"
      ~pr_state:"open"
      ~repo:"owner/repo"
      ~keeper_id:"k1"
      ~turn_id:"t-pr"
      ~comment_count:0
      ~review_status:None
      ~timestamp_ms:2000L;
    Ide_bridge.ingest_turn_event
      ~base_path:base_dir
      ~turn_id:"t-turn"
      ~keeper_id:"k1"
      ~phase:"completed"
      ~model_used:None
      ~tools_used:[]
      ~stop_reason:None
      ~duration_ms:None
      ~timestamp_ms:3000L;
    let events = Ide_bridge.list_events ~base_path:base_dir ~limit:3 () in
    check (list string) "newest-first types" [ "turn"; "pr"; "tool" ]
      (List.map (json_string "type") events);
    check (list int64) "newest-first timestamps" [ 3000L; 2000L; 1000L ]
      (List.map (json_intlit "timestamp_ms") events))
;;

let test_cursor_from_hook_uses_real_file_and_line () =
  with_temp_dir (fun base_dir ->
    let input =
      `Assoc
        [ "file_path", `String "lib/test.ml"
        ; "line_start", `Int 12
        ; "line_end", `Int 14
        ; "column", `Int 3
        ]
    in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"keeper_ide_annotate"
      ~keeper_id:"k1"
      ~turn_id:"turn-7"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:10.0
      ~output_text:"annotated"
      ~input;
    match Ide_bridge.list_cursors ~base_path:base_dir () with
    | [ cursor ] ->
      check string "keeper_id" "k1" (json_string "keeper_id" cursor);
      check string "file_path" "lib/test.ml" (json_string "file_path" cursor);
      check int "line" 12 (json_int "line" cursor);
      check int "column" 3 (json_int "column" cursor);
      check string "focus_mode" "editing" (json_string "focus_mode" cursor);
      check string "tool_name" "keeper_ide_annotate" (json_string "tool_name" cursor);
      check int "turn" 7 (json_int "turn" cursor);
      let selection_end = Yojson.Safe.Util.member "selection_end" cursor in
      check int "selection end line" 14 (json_int "line" selection_end)
    | _ -> fail "expected one cursor")
;;

let test_cursor_from_hook_skips_missing_line () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [ "file_path", `String "lib/test.ml" ] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"keeper_ide_annotate"
      ~keeper_id:"k1"
      ~turn_id:"turn-7"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:10.0
      ~output_text:"annotated"
      ~input;
    check int "no cursor without line" 0
      (List.length (Ide_bridge.list_cursors ~base_path:base_dir ())))
;;

let test_hook_extracts_file_path_from_path_key () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [ "path", `String "lib/test.ml"; "content", `String "hello" ] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"fs_write"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:100.0
      ~output_text:"wrote 10 lines"
      ~input;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let fp = Yojson.Safe.Util.member "file_path" json in
    check string "file_path" "lib/test.ml" (Yojson.Safe.Util.to_string fp))
;;

let test_hook_extracts_file_path_from_file_path_key () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [ "file_path", `String "src/main.ml" ] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"fs_edit"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:50.0
      ~output_text:"edited"
      ~input;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let fp = Yojson.Safe.Util.member "file_path" json in
    check string "file_path" "src/main.ml" (Yojson.Safe.Util.to_string fp))
;;

let test_hook_no_file_path () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [ "command", `String "ls" ] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:10.0
      ~output_text:"file1.ml\nfile2.ml"
      ~input;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let fp = Yojson.Safe.Util.member "file_path" json in
    check bool "file_path is null" true (fp = `Null))
;;

let test_hook_summary_truncation () =
  with_temp_dir (fun base_dir ->
    let long_output = String.make 300 'x' in
    let input = `Assoc [] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:10.0
      ~output_text:long_output
      ~input;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let summary = Yojson.Safe.Util.member "summary" json |> Yojson.Safe.Util.to_string in
    check bool "summary truncated" true (String.length summary <= 200))
;;

let test_hook_typed_outcome_mapping () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"error"
      ~typed_outcome_str:"error"
      ~duration_ms:10.0
      ~output_text:"command failed"
      ~input;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let typed = Yojson.Safe.Util.member "typed_outcome" json |> Yojson.Safe.Util.to_string in
    check string "typed_outcome" "error" typed)
;;

let test_pr_event_ingest () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_pr_event
      ~base_path:base_dir
      ~pr_number:19872
      ~pull_request_url:"https://github.com/jeong-sik/masc/pull/19872"
      ~pr_title:"feat(ide): auto-collect tool/turn events"
      ~pr_state:"open"
      ~repo:"jeong-sik/masc"
      ~keeper_id:"keeper-alpha"
      ~turn_id:"turn-123"
      ~comment_count:0
      ~review_status:None
      ~timestamp_ms:1717400000000L;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let pr_number = Yojson.Safe.Util.member "pr_number" json |> Yojson.Safe.Util.to_int in
    let pull_request_url = Yojson.Safe.Util.member "pull_request_url" json |> Yojson.Safe.Util.to_string in
    check int "pr_number" 19872 pr_number;
    check string "pull_request_url" "https://github.com/jeong-sik/masc/pull/19872" pull_request_url)
;;

let test_pr_event_from_hook_uses_structured_descriptor_output () =
  with_temp_dir (fun base_dir ->
    let output =
      {|{"ok":true,"output":"{\"number\":123,\"url\":\"https://github.com/jeong-sik/masc/pull/123\"}","command_descriptor":{"kind":"gh_pr_create","title":"feat","base":"main","draft":true}}|}
    in
    Ide_bridge.ingest_pr_event_from_hook
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let pr_number = Yojson.Safe.Util.member "pr_number" json |> Yojson.Safe.Util.to_int in
    let pr_title = Yojson.Safe.Util.member "pr_title" json |> Yojson.Safe.Util.to_string in
    check int "pr_number" 123 pr_number;
    check string "pr_title" "feat" pr_title)
;;

let test_pr_event_from_hook_uses_descriptor_confirmed_cli_url () =
  with_temp_dir (fun base_dir ->
    let output =
      {|{"ok":true,"output":"https://github.com/jeong-sik/masc/pull/456","command_descriptor":{"kind":"gh_pr_create","title":"feat cli","base":"main","draft":false}}|}
    in
    Ide_bridge.ingest_pr_event_from_hook
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let pr_number = Yojson.Safe.Util.member "pr_number" json |> Yojson.Safe.Util.to_int in
    let pull_request_url =
      Yojson.Safe.Util.member "pull_request_url" json |> Yojson.Safe.Util.to_string
    in
    check int "pr_number" 456 pr_number;
    check string
      "pull_request_url"
      "https://github.com/jeong-sik/masc/pull/456"
      pull_request_url)
;;

let test_pr_event_from_hook_ignores_non_execute () =
  with_temp_dir (fun base_dir ->
    let output = "https://github.com/owner/repo/pull/456" in
    Ide_bridge.ingest_pr_event_from_hook
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"fs_write";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file not created" false (Sys.file_exists path))
;;

let test_pr_event_from_hook_ignores_no_url () =
  with_temp_dir (fun base_dir ->
    let output = "file written successfully\n" in
    Ide_bridge.ingest_pr_event_from_hook
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file not created" false (Sys.file_exists path))
;;

let test_pr_event_from_hook_ignores_raw_url () =
  with_temp_dir (fun base_dir ->
    let output = "remote: https://github.com/jeong-sik/masc/pull/123\n" in
    Ide_bridge.ingest_pr_event_from_hook
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file not created for raw url" false (Sys.file_exists path))
;;

let test_descriptor_gated_on_success () =
  with_temp_dir (fun base_dir ->
    (* Failed gh pr create with command_descriptor in output should NOT produce PR event *)
    let failed_output = {|{"command_descriptor": {"kind": "gh_pr_create", "title": "feat: test", "base": "main", "draft": true}, "error": "authentication failed"}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:failed_output
      ~tool_name:"execute"
      ~success:false;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file not created on failure" false (Sys.file_exists path))
;;

let test_legacy_hook_uses_explicit_success_flag () =
  with_temp_dir (fun base_dir ->
    let failed_output =
      {|{"ok":false,"output":"https://github.com/jeong-sik/masc/pull/456","command_descriptor":{"kind":"gh_pr_create","title":"feat failed","base":"main","draft":false},"error":"authentication failed"}|}
    in
    Ide_bridge.ingest_pr_event_from_hook
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:failed_output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file not created on failed wrapper result" false (Sys.file_exists path))
;;

let test_descriptor_ingested_on_success () =
  with_temp_dir (fun base_dir ->
    (* Successful gh pr create with command_descriptor should produce PR event *)
    let success_output = {|{"command_descriptor": {"kind": "gh_pr_create", "title": "feat: test", "base": "main", "draft": true}}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:success_output
      ~tool_name:"execute"
      ~success:true;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file created on success" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let pr_number = Yojson.Safe.Util.member "pr_number" json |> Yojson.Safe.Util.to_int in
    check int "pr_number is 0 (no URL in output)" 0 pr_number)
;;

let test_concurrent_ingest () =
  with_temp_dir (fun base_dir ->
    (* Simulate parallel tool calls writing to the same file *)
    let n = 50 in
    let fibers = List.init n (fun i ->
      fun () ->
        Ide_bridge.ingest_tool_event
          ~base_path:base_dir
          ~tool_name:"fs_write"
          ~keeper_id:"k1"
          ~turn_id:(Printf.sprintf "t-%d" i)
          ~outcome:"success"
          ~typed_outcome:"progress"
          ~latency_ms:i
          ~summary:(Printf.sprintf "event %d" i)
          ~file_path:None
          ~timestamp_ms:(Int64.of_int (1000 + i))
          ())
    in
    (* Run all fibers concurrently via Eio *)
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        List.iter (fun f -> Eio.Fiber.fork ~sw f) fibers));
    (* Verify all events were written *)
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let count = ref 0 in
    (try while true do ignore (input_line ic); incr count done with End_of_file -> ());
    close_in ic;
    check int "all events written" n !count)
;;

(* ── Segment rotation + tail-read (IDE v2 A2/A3) ──────────────────── *)

let tool_row i =
  `Assoc
    [ "type", `String "tool"
    ; "keeper_id", `String "k1"
    ; "timestamp_ms", `Int i
    ; "turn_id", `String (Printf.sprintf "t-%d" i)
    ]
;;

let row_timestamp line =
  Yojson.Safe.from_string line
  |> Yojson.Safe.Util.member "timestamp_ms"
  |> Yojson.Safe.Util.to_int
;;

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         match input_line ic with
         | line -> loop (line :: acc)
         | exception End_of_file -> List.rev acc
       in
       loop [])
;;

(* (a) The live segment rotates to a numbered archive once it reaches the
   size threshold; the live filename stays stable. *)
let test_segment_rotates_on_threshold () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    for i = 1 to 6 do
      Ide_bridge.For_testing.append_rotating
        ~path
        ~max_segment_bytes:100
        ~max_retained_segments:8
        (tool_row i)
    done;
    check bool "live segment exists" true (Sys.file_exists path);
    check bool "at least one archive created" true
      (List.length (Ide_bridge.For_testing.archive_indices ~path) >= 1))
;;

(* (b)+(d) A budget-limited tail-read of a 100-row live segment returns
   exactly the newest [budget] rows — not the whole file — proving the read
   cost is bounded by [budget], not by file size. *)
let test_tail_read_returns_newest_bounded () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    for i = 1 to 100 do
      Ide_bridge.For_testing.append_rotating
        ~path
        ~max_segment_bytes:max_int (* never rotate: single live segment *)
        ~max_retained_segments:8
        (tool_row i)
    done;
    let lines = Ide_bridge.For_testing.tail_read_lines ~path ~budget:5 in
    check int "reads only budget rows, not all 100" 5 (List.length lines);
    check (list int) "newest five rows, oldest-first"
      [ 96; 97; 98; 99; 100 ]
      (List.map row_timestamp lines))
;;

(* (c) When the budget exceeds the newest segment's rows, the tail-read
   expands into the previous segment. Rows 1..3 land in archive .1, rows
   4..6 in the live segment; a budget of 5 returns the newest 5 overall
   (rows 2..6), drawing from both segments. *)
let test_tail_read_crosses_boundary () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    let append ~cap i =
      Ide_bridge.For_testing.append_rotating
        ~path ~max_segment_bytes:cap ~max_retained_segments:8 (tool_row i)
    in
    List.iter (fun i -> append ~cap:max_int i) [ 1; 2; 3 ];
    append ~cap:1 4 (* rotates rows 1..3 into an archive, row 4 into fresh live *);
    List.iter (fun i -> append ~cap:max_int i) [ 5; 6 ];
    check int "one archive present" 1
      (List.length (Ide_bridge.For_testing.archive_indices ~path));
    let lines = Ide_bridge.For_testing.tail_read_lines ~path ~budget:5 in
    check int "budget rows collected across segments" 5 (List.length lines);
    let timestamps = List.map row_timestamp lines |> List.sort compare in
    check (list int) "newest five across both segments" [ 2; 3; 4; 5; 6 ] timestamps)
;;

(* (e) Retention prunes the oldest archives, keeping at most
   [max_retained_segments] of them (the most recent by index). *)
let test_retention_prunes_old_segments () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    for i = 1 to 10 do
      Ide_bridge.For_testing.append_rotating
        ~path ~max_segment_bytes:1 ~max_retained_segments:2 (tool_row i)
    done;
    check bool "live segment exists" true (Sys.file_exists path);
    check (list int) "keeps only the two newest archives"
      [ 8; 9 ]
      (List.sort compare (Ide_bridge.For_testing.archive_indices ~path)))
;;

let test_concurrent_rotation_preserves_rows () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    let workers = 8 in
    let per_worker = 20 in
    let domains =
      List.init workers (fun worker ->
        Domain.spawn (fun () ->
          for i = 1 to per_worker do
            let row_id = (worker * 1000) + i in
            Ide_bridge.For_testing.append_rotating
              ~path
              ~max_segment_bytes:1
              ~max_retained_segments:(workers * per_worker)
              (tool_row row_id)
          done))
    in
    List.iter Domain.join domains;
    let timestamps =
      Ide_bridge.For_testing.segment_paths_newest_first ~path
      |> List.concat_map read_lines
      |> List.map row_timestamp
      |> List.sort_uniq compare
    in
    check
      int
      "concurrent rotations preserve every appended row"
      (workers * per_worker)
      (List.length timestamps))
;;

(* Integration: [list_events] merges live and archived segments through the
   public API, newest-first. *)
let test_list_events_reads_across_segments () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~tool_name:"write_file"
      ~keeper_id:"k1"
      ~turn_id:"t-live"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:10
      ~summary:"live"
      ~file_path:None
      ~timestamp_ms:5000L
      ();
    let dir = Ide_paths.partition_store_dir ~base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let oc = open_out (path ^ ".1") in
    output_string oc
      ({|{"type":"tool","keeper_id":"k1","timestamp_ms":1000,"turn_id":"t-arch"}|}
       ^ "\n");
    close_out oc;
    let events =
      Ide_bridge.list_events ~base_path:base_dir ~kind:Ide_bridge.Tool ~limit:10 ()
    in
    check int "reads both live and archived segments" 2 (List.length events);
    check (list string) "newest-first across segments" [ "t-live"; "t-arch" ]
      (List.map (json_string "turn_id") events))
;;

let () =
  run
    "ide_bridge"
    [ ( "parse_pull_request_result"
      , [ test_case "direct json" `Quick test_parse_pull_request_result_direct_json
        ; test_case "wrapped json" `Quick test_parse_pull_request_result_wrapped_json
        ; test_case "html_url preferred" `Quick test_parse_pull_request_result_prefers_html_url
        ; test_case "raw url ignored" `Quick test_parse_pull_request_result_ignores_raw_url
        ; test_case "no number" `Quick test_parse_pull_request_result_no_number
        ] )
    ; ( "ingest"
      , [ test_case "tool event" `Quick test_ingest_tool_event
        ; test_case "turn event" `Quick test_ingest_turn_event
        ; test_case "multiple events" `Quick test_ingest_multiple_events
        ] )
    ; ( "read"
      , [ test_case "filters keeper and pages" `Quick test_list_events_filters_keeper_and_pages
        ; test_case "merges kinds newest first" `Quick test_list_events_merges_kinds_newest_first
        ; test_case "reads across segments" `Quick test_list_events_reads_across_segments
        ] )
    ; ( "rotation"
      , [ test_case "rotates on threshold" `Quick test_segment_rotates_on_threshold
        ; test_case "tail-read returns newest bounded" `Quick
            test_tail_read_returns_newest_bounded
        ; test_case "tail-read crosses segment boundary" `Quick
            test_tail_read_crosses_boundary
        ; test_case "retention prunes old segments" `Quick
            test_retention_prunes_old_segments
        ; test_case "concurrent rotations preserve rows" `Quick
            test_concurrent_rotation_preserves_rows
        ] )
    ; ( "cursor"
      , [ test_case "from hook uses real file and line" `Quick test_cursor_from_hook_uses_real_file_and_line
        ; test_case "from hook skips missing line" `Quick test_cursor_from_hook_skips_missing_line
        ] )
    ; ( "hook_extract"
      , [ test_case "file_path from path key" `Quick test_hook_extracts_file_path_from_path_key
        ; test_case "file_path from file_path key" `Quick test_hook_extracts_file_path_from_file_path_key
        ; test_case "no file_path (execute)" `Quick test_hook_no_file_path
        ; test_case "summary truncation" `Quick test_hook_summary_truncation
        ; test_case "typed_outcome mapping" `Quick test_hook_typed_outcome_mapping
        ] )
    ; ( "pr_event"
      , [ test_case "pr event ingest" `Quick test_pr_event_ingest
        ; test_case "from hook uses structured descriptor output" `Quick test_pr_event_from_hook_uses_structured_descriptor_output
        ; test_case "from hook uses descriptor-confirmed CLI URL" `Quick test_pr_event_from_hook_uses_descriptor_confirmed_cli_url
        ; test_case "from hook ignores non-execute" `Quick test_pr_event_from_hook_ignores_non_execute
        ; test_case "from hook ignores no url" `Quick test_pr_event_from_hook_ignores_no_url
        ; test_case "from hook ignores raw url" `Quick test_pr_event_from_hook_ignores_raw_url
        ; test_case "descriptor gated on success" `Quick test_descriptor_gated_on_success
        ; test_case "legacy hook uses explicit success flag" `Quick test_legacy_hook_uses_explicit_success_flag
        ; test_case "descriptor ingested on success" `Quick test_descriptor_ingested_on_success
        ] )
    ; ( "concurrency"
      , [ test_case "concurrent ingest" `Quick test_concurrent_ingest
        ] )
    ]
