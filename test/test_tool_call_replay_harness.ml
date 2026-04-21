open Masc_mcp
open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let fixture_path name =
  Filename.concat (source_root ()) ("test/fixtures/tool_call_replay/" ^ name)

let load_fixture () =
  match Tool_call_replay_harness.load_snapshots_from_jsonl
          (fixture_path "openai_tool_call.jsonl")
  with
  | Ok [snapshot] -> snapshot
  | Ok snapshots ->
      Alcotest.failf "expected one snapshot, got %d" (List.length snapshots)
  | Error msg -> Alcotest.fail msg

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

let test_load_fixture_snapshot () =
  let snapshot = load_fixture () in
  check string "snapshot id" "glm-tool-call-001" snapshot.id;
  check string "provider" "glm" snapshot.provider;
  check (list string) "declared tools"
    [ "masc_add_task"; "masc_status" ]
    snapshot.tools;
  match snapshot.expected_tool_calls with
  | [tool_call] ->
      check string "expected tool" "masc_add_task" tool_call.name
  | _ -> Alcotest.fail "expected exactly one tool call"

let test_validate_fixture_snapshot () =
  let snapshot = load_fixture () in
  match Tool_call_replay_harness.validate_snapshot snapshot with
  | Ok () -> ()
  | Error errors ->
      Alcotest.failf "fixture should validate: %s" (String.concat "; " errors)

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

let test_load_rejects_malformed_jsonl () =
  let dir = Filename.temp_file "tool-call-replay" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "broken.jsonl" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      if Sys.file_exists dir then Unix.rmdir dir)
    (fun () ->
      Fs_compat.save_file path
        {|{"id":"ok","provider":"glm","goal":"x","tools":[],"response":{"choices":[]},"expected_tool_calls":[]}
not-json
|};
      match Tool_call_replay_harness.load_snapshots_from_jsonl path with
      | Ok _ -> Alcotest.fail "expected malformed JSONL to fail"
      | Error msg ->
          check bool "malformed line surfaced" true
            (contains_substring msg "malformed JSONL line"))

let () =
  Alcotest.run "tool_call_replay_harness"
    [
      ( "replay",
        [
          Alcotest.test_case "load fixture snapshot" `Quick
            test_load_fixture_snapshot;
          Alcotest.test_case "validate fixture snapshot" `Quick
            test_validate_fixture_snapshot;
          Alcotest.test_case "reject undeclared tool" `Quick
            test_validate_rejects_undeclared_tool;
          Alcotest.test_case "reject argument mismatch" `Quick
            test_validate_rejects_argument_mismatch;
          Alcotest.test_case "reject malformed jsonl" `Quick
            test_load_rejects_malformed_jsonl;
        ] );
    ]
