open Alcotest

module Eval_feed = Masc_mcp.Dashboard_eval_feed

let test_counter = ref 0

let tmpdir prefix =
  incr test_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%d" prefix (Unix.getpid ()) !test_counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let mkdir_p path =
  let rec aux current = function
    | [] -> ()
    | seg :: rest ->
        let next = Filename.concat current seg in
        (try Unix.mkdir next 0o755
         with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        aux next rest
  in
  let segments = String.split_on_char '/' path in
  match segments with
  | "" :: rest -> aux "/" rest
  | _ -> aux "." segments

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* ── Sample JSON fixtures ────────────────────────────────────────── *)

let valid_verdict_json =
  {|{
    "schema_version": 1,
    "all_passed": true,
    "coverage": 0.85,
    "layer_results": [
      {
        "layer_name": "ToolSelected",
        "passed": true,
        "score": 0.95,
        "evidence": ["correct tool chosen"],
        "detail": null
      },
      {
        "layer_name": "CompletesWithin",
        "passed": true,
        "score": 1.0,
        "evidence": ["3/5 turns"],
        "detail": "within budget"
      },
      {
        "layer_name": "ContainsText",
        "passed": false,
        "score": null,
        "evidence": ["missing expected output", "partial match"],
        "detail": null
      }
    ]
  }|}

let valid_snapshot_json =
  Printf.sprintf
    {|{
    "agent_name": "keeper-a",
    "session_id": "sess-001",
    "worker_run_id": "run-abc-123",
    "timestamp": 1700000000.0,
    "coverage": 0.85,
    "baseline_status": "Improved",
    "verdict": %s
  }|}
    valid_verdict_json

(* ── Verdict parsing tests ───────────────────────────────────────── *)

let test_parse_valid_verdict () =
  let json = Yojson.Safe.from_string valid_verdict_json in
  match Eval_feed.read_verdict_json json with
  | Error msg -> fail ("unexpected error: " ^ msg)
  | Ok verdict ->
      check int "schema_version" 1 verdict.schema_version;
      check bool "all_passed" true verdict.all_passed;
      check (float 0.001) "coverage" 0.85 verdict.coverage;
      check int "layer count" 3 (List.length verdict.layer_results);
      let first = List.nth verdict.layer_results 0 in
      check string "first layer name" "ToolSelected" first.layer_name;
      check bool "first passed" true first.passed;
      (match first.score with
      | Some s -> check (float 0.001) "first score" 0.95 s
      | None -> fail "expected score for first layer");
      check (list string) "first evidence" [ "correct tool chosen" ]
        first.evidence;
      let third = List.nth verdict.layer_results 2 in
      check string "third layer name" "ContainsText" third.layer_name;
      check bool "third passed" false third.passed;
      check bool "third score is none" true (Option.is_none third.score);
      check (list string) "third evidence"
        [ "missing expected output"; "partial match" ]
        third.evidence

let test_parse_wrong_schema_version () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version": 2, "all_passed": true, "coverage": 0.5, "layer_results": []}|}
  in
  match Eval_feed.read_verdict_json json with
  | Ok _ -> fail "expected error for schema_version 2"
  | Error msg ->
      check bool "error mentions schema_version" true
        (String.length msg > 0);
      check bool "error mentions version 2" true
        (try
           ignore (Str.search_forward (Str.regexp_string "2") msg 0);
           true
         with Not_found -> false)

let test_parse_missing_schema_version () =
  let json =
    Yojson.Safe.from_string
      {|{"all_passed": true, "coverage": 0.5, "layer_results": []}|}
  in
  match Eval_feed.read_verdict_json json with
  | Ok _ -> fail "expected error for missing schema_version"
  | Error _ -> ()

let test_parse_empty_layer_results () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version": 1, "all_passed": true, "coverage": 1.0, "layer_results": []}|}
  in
  match Eval_feed.read_verdict_json json with
  | Error msg -> fail ("unexpected error: " ^ msg)
  | Ok verdict ->
      check bool "all_passed" true verdict.all_passed;
      check int "layer count" 0 (List.length verdict.layer_results)

let test_parse_layer_missing_name () =
  let json =
    Yojson.Safe.from_string
      {|{
        "schema_version": 1, "all_passed": false, "coverage": 0.0,
        "layer_results": [{"passed": true, "evidence": []}]
      }|}
  in
  match Eval_feed.read_verdict_json json with
  | Ok _ -> fail "expected error for missing layer_name"
  | Error msg ->
      check bool "error mentions layer_name" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "layer_name") msg 0);
           true
         with Not_found -> false)

(* ── read_latest tests ───────────────────────────────────────────── *)

let test_read_latest_empty_dir () =
  let base = tmpdir "eval_empty" in
  let result = Eval_feed.read_latest ~base_path:base ~agent_name:"keeper-a" ~limit:10 in
  check int "empty result" 0 (List.length result)

let test_read_latest_nonexistent_dir () =
  let result =
    Eval_feed.read_latest ~base_path:"/nonexistent/path"
      ~agent_name:"keeper-a" ~limit:10
  in
  check int "empty result" 0 (List.length result)

let test_read_latest_with_files () =
  let base = tmpdir "eval_files" in
  let eval_dir =
    Filename.concat
      (Filename.concat (Filename.concat base ".oas") "eval")
      "keeper-a"
  in
  mkdir_p eval_dir;
  (* Write two valid snapshot files *)
  write_file
    (Filename.concat eval_dir "001.json")
    (Printf.sprintf
       {|{
         "worker_run_id": "run-001",
         "timestamp": 1700000001.0,
         "coverage": 0.80,
         "baseline_status": "Unchanged",
         "verdict": %s
       }|}
       valid_verdict_json);
  write_file
    (Filename.concat eval_dir "002.json")
    (Printf.sprintf
       {|{
         "worker_run_id": "run-002",
         "session_id": "sess-002",
         "timestamp": 1700000002.0,
         "coverage": 0.90,
         "baseline_status": "Improved",
         "verdict": %s
       }|}
       valid_verdict_json);
  (* Write one invalid file *)
  write_file (Filename.concat eval_dir "003.json") {|{"invalid": true}|};
  (* Write a non-json file that should be ignored *)
  write_file (Filename.concat eval_dir "readme.txt") "ignore me";
  let results =
    Eval_feed.read_latest ~base_path:base ~agent_name:"keeper-a" ~limit:10
  in
  check int "two valid snapshots" 2 (List.length results);
  (* Sorted by filename descending, so 002 comes first *)
  let first = List.nth results 0 in
  check string "first worker_run_id" "run-002" first.worker_run_id;
  check string "first agent_name" "keeper-a" first.agent_name;
  check (float 0.001) "first coverage" 0.85 first.verdict.coverage;
  (match first.session_id with
  | Some sid -> check string "first session_id" "sess-002" sid
  | None -> fail "expected session_id for first snapshot");
  (match first.baseline_status with
  | Some bs -> check string "first baseline_status" "Improved" bs
  | None -> fail "expected baseline_status for first snapshot");
  let second = List.nth results 1 in
  check string "second worker_run_id" "run-001" second.worker_run_id;
  check (float 0.001) "second coverage" 0.85 second.verdict.coverage

let test_read_latest_with_limit () =
  let base = tmpdir "eval_limit" in
  let eval_dir =
    Filename.concat
      (Filename.concat (Filename.concat base ".oas") "eval")
      "keeper-b"
  in
  mkdir_p eval_dir;
  for i = 1 to 5 do
    write_file
      (Filename.concat eval_dir (Printf.sprintf "%03d.json" i))
      (Printf.sprintf
         {|{
           "worker_run_id": "run-%03d",
           "timestamp": %f,
           "coverage": 0.5,
           "verdict": %s
         }|}
         i
         (1700000000.0 +. float_of_int i)
         valid_verdict_json)
  done;
  let results =
    Eval_feed.read_latest ~base_path:base ~agent_name:"keeper-b" ~limit:2
  in
  check int "limited to 2" 2 (List.length results)

(* ── Serialization roundtrip ─────────────────────────────────────── *)

let test_snapshot_json_roundtrip () =
  let json = Yojson.Safe.from_string valid_snapshot_json in
  match Eval_feed.read_verdict_json (Yojson.Safe.Util.member "verdict" json) with
  | Error msg -> fail ("verdict parse failed: " ^ msg)
  | Ok verdict ->
      let snapshot : Eval_feed.eval_snapshot =
        {
          agent_name = "keeper-a";
          session_id = Some "sess-001";
          worker_run_id = "run-abc-123";
          timestamp = 1700000000.0;
          verdict;
          baseline_status = Some "Improved";
        }
      in
      let json_out = Eval_feed.snapshot_to_json snapshot in
      let agent =
        Masc_mcp.Safe_ops.json_string ~default:"" "agent_name" json_out
      in
      check string "agent_name roundtrip" "keeper-a" agent;
      let verdict_j = Yojson.Safe.Util.member "verdict" json_out in
      let sv =
        Masc_mcp.Safe_ops.json_int ~default:0 "schema_version" verdict_j
      in
      check int "schema_version in output" 1 sv

let test_verdict_to_json () =
  let verdict : Eval_feed.swiss_verdict_json =
    {
      schema_version = 1;
      all_passed = false;
      coverage = 0.42;
      layer_results =
        [
          {
            layer_name = "L1";
            passed = true;
            score = Some 0.9;
            evidence = [ "ok" ];
            detail = None;
          };
        ];
    }
  in
  let json = Eval_feed.verdict_to_json verdict in
  let ap = Masc_mcp.Safe_ops.json_bool ~default:true "all_passed" json in
  check bool "all_passed false" false ap;
  let cov = Masc_mcp.Safe_ops.json_float ~default:0.0 "coverage" json in
  check (float 0.001) "coverage" 0.42 cov

(* ── Test suite ──────────────────────────────────────────────────── *)

let () =
  run "Dashboard_eval_feed"
    [
      ( "verdict_parsing",
        [
          test_case "valid verdict" `Quick test_parse_valid_verdict;
          test_case "wrong schema_version" `Quick
            test_parse_wrong_schema_version;
          test_case "missing schema_version" `Quick
            test_parse_missing_schema_version;
          test_case "empty layer_results" `Quick
            test_parse_empty_layer_results;
          test_case "layer missing name" `Quick test_parse_layer_missing_name;
        ] );
      ( "read_latest",
        [
          test_case "empty directory" `Quick test_read_latest_empty_dir;
          test_case "nonexistent directory" `Quick
            test_read_latest_nonexistent_dir;
          test_case "with files" `Quick test_read_latest_with_files;
          test_case "with limit" `Quick test_read_latest_with_limit;
        ] );
      ( "serialization",
        [
          test_case "snapshot roundtrip" `Quick test_snapshot_json_roundtrip;
          test_case "verdict_to_json" `Quick test_verdict_to_json;
        ] );
    ]
