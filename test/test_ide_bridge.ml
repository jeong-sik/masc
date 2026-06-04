(** Tests for IDE Bridge — event collection and PR URL parsing. *)

open Alcotest

let test_parse_pr_url_simple () =
  match Ide_bridge.parse_pr_url_from_output "https://github.com/jeong-sik/masc/pull/19872" with
  | Some (number, url) ->
    check int "pr number" 19872 number;
    check string "pr url" "https://github.com/jeong-sik/masc/pull/19872" url
  | None -> fail "expected Some"
;;

let test_parse_pr_url_with_files () =
  match Ide_bridge.parse_pr_url_from_output "https://github.com/jeong-sik/masc/pull/19872/files" with
  | Some (number, url) ->
    check int "pr number" 19872 number;
    check string "pr url" "https://github.com/jeong-sik/masc/pull/19872" url
  | None -> fail "expected Some"
;;

let test_parse_pr_url_in_output () =
  let output = "remote: Create a pull request for 'feat/branch' on GitHub by visiting:\nremote:      https://github.com/jeong-sik/masc/pull/123\n" in
  match Ide_bridge.parse_pr_url_from_output output with
  | Some (number, _) -> check int "pr number" 123 number
  | None -> fail "expected Some"
;;

let test_parse_pr_url_no_match () =
  check (option (pair int string)) "no pr url"
    None
    (Ide_bridge.parse_pr_url_from_output "nothing here")
;;

let test_parse_pr_url_no_number () =
  check (option (pair int string)) "no number"
    None
    (Ide_bridge.parse_pr_url_from_output "https://github.com/owner/repo/pull/abc")
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
      ~pr_url:"https://github.com/jeong-sik/masc/pull/19872"
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
    let pr_url = Yojson.Safe.Util.member "pr_url" json |> Yojson.Safe.Util.to_string in
    check int "pr_number" 19872 pr_number;
    check string "pr_url" "https://github.com/jeong-sik/masc/pull/19872" pr_url)
;;

let test_descriptor_gated_on_success () =
  with_temp_dir (fun base_dir ->
    (* Failed gh pr create with command_descriptor in output should NOT produce PR event *)
    let failed_output = {|{"command_descriptor": {"kind": "gh_pr_create", "title": "feat: test", "base": "main", "draft": true}, "error": "authentication failed"}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      { Ide_bridge.pr_base_path = base_dir
      ; pr_keeper_id = "k1"
      ; pr_turn_id = "t1"
      ; pr_output_text = failed_output
      ; pr_success = false
      };
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file not created on failure" false (Sys.file_exists path))
;;

let test_descriptor_ingested_on_success () =
  with_temp_dir (fun base_dir ->
    (* Successful gh pr create with command_descriptor should produce PR event *)
    let success_output = {|{"command_descriptor": {"kind": "gh_pr_create", "title": "feat: test", "base": "main", "draft": true}}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      { Ide_bridge.pr_base_path = base_dir
      ; pr_keeper_id = "k1"
      ; pr_turn_id = "t1"
      ; pr_output_text = success_output
      ; pr_success = true
      };
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

let () =
  run
    "ide_bridge"
    [ ( "parse_pr_url"
      , [ test_case "simple url" `Quick test_parse_pr_url_simple
        ; test_case "url with /files" `Quick test_parse_pr_url_with_files
        ; test_case "url in output" `Quick test_parse_pr_url_in_output
        ; test_case "no match" `Quick test_parse_pr_url_no_match
        ; test_case "no number" `Quick test_parse_pr_url_no_number
        ] )
    ; ( "ingest"
      , [ test_case "tool event" `Quick test_ingest_tool_event
        ; test_case "turn event" `Quick test_ingest_turn_event
        ; test_case "multiple events" `Quick test_ingest_multiple_events
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
        ; test_case "descriptor gated on success" `Quick test_descriptor_gated_on_success
        ; test_case "descriptor ingested on success" `Quick test_descriptor_ingested_on_success
        ] )
    ; ( "concurrency"
      , [ test_case "concurrent ingest" `Quick test_concurrent_ingest
        ] )
    ]
