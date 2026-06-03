(** Tests for IDE Bridge — event collection and PR URL parsing. *)

open Alcotest

let test_parse_pr_url_simple () =
  match Ide_bridge.parse_pr_url_from_output "https://github.com/jeong-sik/masc-mcp/pull/19872" with
  | Some (number, url) ->
    check int "pr number" 19872 number;
    check string "pr url" "https://github.com/jeong-sik/masc-mcp/pull/19872" url
  | None -> fail "expected Some"
;;

let test_parse_pr_url_with_files () =
  match Ide_bridge.parse_pr_url_from_output "https://github.com/jeong-sik/masc-mcp/pull/19872/files" with
  | Some (number, url) ->
    check int "pr number" 19872 number;
    check string "pr url" "https://github.com/jeong-sik/masc-mcp/pull/19872" url
  | None -> fail "expected Some"
;;

let test_parse_pr_url_in_output () =
  let output = "remote: Create a pull request for 'feat/branch' on GitHub by visiting:\nremote:      https://github.com/jeong-sik/masc-mcp/pull/123\n" in
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
      ~timestamp_ms:1717400000000L;
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
      ~timestamp_ms:1000L;
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
      ~timestamp_ms:2000L;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let count = ref 0 in
    (try while true do ignore (input_line ic); incr count done with End_of_file -> ());
    close_in ic;
    check int "two events" 2 !count)
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
    ]
