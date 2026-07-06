open Masc
open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let fixture_dir () =
  Filename.concat (source_root ()) "test/fixtures/tool_call_replay"

let fixture_path name =
  Filename.concat (fixture_dir ()) name

type valid_fixture_case = {
  file_name : string;
  expected_id : string;
  expected_provider : string;
  expected_tool : string;
}

let valid_fixture_cases =
  [
    {
      file_name = "openai_tool_call.jsonl";
      expected_id = "glm-coding-tool-call-001";
      expected_provider = "glm-coding";
      expected_tool = "masc_add_task";
    };
    {
      file_name = "anthropic_tool_call.jsonl";
      expected_id = "anthropic-tool-call-001";
      expected_provider = "anthropic";
      expected_tool = "gh_issue_list";
    };
    {
      file_name = "dashscope_tool_call.jsonl";
      expected_id = "dashscope-tool-call-001";
      expected_provider = "dashscope";
      expected_tool = "search_files";
    };
    {
      file_name = "gemini_tool_call.jsonl";
      expected_id = "gemini-tool-call-001";
      expected_provider = "gemini";
      expected_tool = "search_files";
    };
    {
      file_name = "kimi_tool_call.jsonl";
      expected_id = "kimi-tool-call-001";
      expected_provider = "kimi";
      expected_tool = "masc_add_task";
    };
    {
      file_name = "ollama_tool_call.jsonl";
      expected_id = "ollama-tool-call-001";
      expected_provider = "ollama";
      expected_tool = "masc_status";
    };
  ]

let declared_fixture_files =
  List.sort String.compare
    (List.map (fun case -> case.file_name) valid_fixture_cases
     @ [
         "empty_provider.jsonl";
         "malformed_jsonl.jsonl";
         "missing_fields.jsonl";
       ])

let load_single_fixture file_name =
  match Tool_call_replay_harness.load_snapshots_from_jsonl
          (fixture_path file_name)
  with
  | Ok [snapshot] -> snapshot
  | Ok snapshots ->
      Alcotest.failf "%s: expected one snapshot, got %d" file_name
        (List.length snapshots)
  | Error msg -> Alcotest.fail msg

let load_fixture () =
  load_single_fixture "openai_tool_call.jsonl"

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let read_nonempty_lines path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
      let rec loop acc =
        match input_line input with
        | line ->
            let line = String.trim line in
            if String.equal line "" then loop acc else loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let with_temp_jsonl content f =
  let path = Filename.temp_file "tool-call-replay-row" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Fs_compat.save_file path (content ^ "\n");
      f path)

let test_load_fixture_snapshot () =
  let snapshot = load_fixture () in
  check string "snapshot id" "glm-coding-tool-call-001" snapshot.id;
  check string "provider" "glm-coding" snapshot.provider;
  check (list string) "declared tools"
    [ "masc_add_task"; "masc_status" ]
    snapshot.tools;
  match snapshot.expected_tool_calls with
  | [tool_call] ->
      check string "expected tool" "masc_add_task" tool_call.name
  | _ -> Alcotest.fail "expected exactly one tool call"

let test_declared_fixture_catalog_matches_directory () =
  let actual =
    Sys.readdir (fixture_dir ())
    |> Array.to_list
    |> List.sort String.compare
  in
  check (list string) "fixture catalog covers directory" declared_fixture_files
    actual

let test_validate_fixture_snapshot () =
  let snapshot = load_fixture () in
  match Tool_call_replay_harness.validate_snapshot snapshot with
  | Ok () -> ()
  | Error errors ->
      Alcotest.failf "fixture should validate: %s" (String.concat "; " errors)

let test_validate_declared_fixture_catalog () =
  List.iter
    (fun case ->
      let snapshot = load_single_fixture case.file_name in
      check string (case.file_name ^ " id") case.expected_id snapshot.id;
      check string (case.file_name ^ " provider") case.expected_provider
        snapshot.provider;
      check bool (case.file_name ^ " declares expected tool") true
        (List.exists (String.equal case.expected_tool) snapshot.tools);
      match Tool_call_replay_harness.validate_snapshot snapshot with
      | Ok () -> ()
      | Error errors ->
          Alcotest.failf "%s should validate: %s" case.file_name
            (String.concat "; " errors))
    valid_fixture_cases

let test_validate_rejects_undeclared_tool () =
  let snapshot = load_fixture () in
  let bad_snapshot = { snapshot with tools = [ "masc_status" ] } in
  match Tool_call_replay_harness.validate_snapshot bad_snapshot with
  | Ok () -> Alcotest.fail "expected undeclared tool validation to fail"
  | Error errors ->
      let joined = String.concat " | " errors in
      check bool "expected tool error" true
        (contains_substring joined "expected tool 'masc_add_task' is not declared");
      check bool "response tool error" true
        (contains_substring joined "response tool 'masc_add_task' is not declared")

let test_validate_rejects_argument_mismatch () =
  let snapshot = load_fixture () in
  let bad_snapshot =
    {
      snapshot with
      expected_tool_calls =
        [
          {
            Tool_call_replay_harness.name = "masc_add_task";
            arguments =
              `Assoc
                [
                  ("title", `String "Different title");
                  ("description", `String "Trace sandbox_profile precedence");
                ];
          };
        ];
    }
  in
  match Tool_call_replay_harness.validate_snapshot bad_snapshot with
  | Ok () -> Alcotest.fail "expected argument mismatch to fail"
  | Error errors ->
      let joined = String.concat " | " errors in
      check bool "argument mismatch surfaced" true
        (contains_substring joined "arguments mismatch for tool 'masc_add_task'")

let test_fixture_catalog_rejects_empty_provider () =
  let snapshot = load_single_fixture "empty_provider.jsonl" in
  match Tool_call_replay_harness.validate_snapshot snapshot with
  | Ok () -> Alcotest.fail "expected empty provider validation to fail"
  | Error errors ->
      let joined = String.concat " | " errors in
      check bool "empty provider surfaced" true
        (contains_substring joined "snapshot provider must be non-empty")

let test_fixture_catalog_rejects_missing_fields () =
  let rows = read_nonempty_lines (fixture_path "missing_fields.jsonl") in
  let expected_errors =
    [
      "tools: missing required field";
      "response: missing required field";
      "id: missing required field";
    ]
  in
  check int "missing field row count" (List.length expected_errors)
    (List.length rows);
  List.iter2
    (fun row expected_error ->
      with_temp_jsonl row (fun path ->
        match Tool_call_replay_harness.load_snapshots_from_jsonl path with
        | Ok _ -> Alcotest.failf "expected row to fail: %s" expected_error
        | Error msg ->
            check bool ("missing field surfaced: " ^ expected_error) true
              (contains_substring msg expected_error)))
    rows expected_errors

let test_load_rejects_malformed_jsonl () =
  match
    Tool_call_replay_harness.load_snapshots_from_jsonl
      (fixture_path "malformed_jsonl.jsonl")
  with
  | Ok _ -> Alcotest.fail "expected malformed JSONL fixture to fail"
  | Error msg ->
      check bool "malformed line surfaced" true
        (contains_substring msg "malformed JSONL line")

let () =
  Alcotest.run "tool_call_replay_harness"
    [
      ( "replay",
        [
          Alcotest.test_case "load fixture snapshot" `Quick
            test_load_fixture_snapshot;
          Alcotest.test_case "declared fixture catalog matches directory" `Quick
            test_declared_fixture_catalog_matches_directory;
          Alcotest.test_case "validate fixture snapshot" `Quick
            test_validate_fixture_snapshot;
          Alcotest.test_case "validate declared fixture catalog" `Quick
            test_validate_declared_fixture_catalog;
          Alcotest.test_case "reject undeclared tool" `Quick
            test_validate_rejects_undeclared_tool;
          Alcotest.test_case "reject argument mismatch" `Quick
            test_validate_rejects_argument_mismatch;
          Alcotest.test_case "reject empty provider fixture" `Quick
            test_fixture_catalog_rejects_empty_provider;
          Alcotest.test_case "reject missing field fixtures" `Quick
            test_fixture_catalog_rejects_missing_fields;
          Alcotest.test_case "reject malformed jsonl fixture" `Quick
            test_load_rejects_malformed_jsonl;
        ] );
    ]
