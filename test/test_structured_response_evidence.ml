open Alcotest
open Masc

module Artifact_id = Shared_types.Artifact_id
module Evidence = Structured_response_evidence
module Error = Agent_core.Error

let with_workspace f =
  let base_path = Filename.temp_file "structured-response-evidence-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let attempt invocation_id attempt_index : Evidence.attempt =
  { source=Vision; invocation_id; runtime_id="actual-candidate"; attempt_index;
    tool_use_id=Some "original-tool-call"; trace_id=Some "original-trace" }
;;

let records base_path =
  let dir = Evidence.record_path ~base_path (Evidence.invocation_id ()) |> Filename.dirname in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
  |> List.map (fun name ->
    let path = Filename.concat dir name in
    let bytes = Fs_compat.load_file path in
    check int "private evidence permissions" 0o600 ((Unix.stat path).st_perm land 0o777);
    path, Yojson.Safe.from_string bytes)
;;

let field key json = Yojson.Safe.Util.member key json

let test_actual_bounded_error_survives_distinct_attempts () = with_workspace @@ fun base_path ->
  let invocation_id = Evidence.invocation_id () in
  let raw = "~private-original-output~" ^ String.concat "" (List.init 2000 (fun _ -> "한")) in
  let error = Error.structured_output_parse_error ~reason:Invalid_json
    ~detail:"~private-parser-detail~" ~raw in
  let details = List.init 2 (fun index -> Evidence.record_failure
    ~base_path:(Some base_path) ~attempt:(attempt invocation_id index) error) in
  let rows = records base_path in
  check int "two attempts are retained independently" 2 (List.length rows);
  List.iter (fun (_,row) ->
    let preview = field "raw_preview" row |> Yojson.Safe.Util.to_string in
    check bool "actual original bytes retained at a UTF-8 boundary" true
      (String.starts_with ~prefix:preview raw && String.is_valid_utf_8 preview
       && String.length preview <= 4096);
    check int "full original byte count survives" (String.length raw)
      (field "raw_len" row |> Yojson.Safe.Util.to_int);
    check string "exact original parser detail" "~private-parser-detail~"
      (field "parser_detail" row |> Yojson.Safe.Util.to_string);
    check string "same original parent invocation" "original-tool-call"
      (field "tool_use_id" row |> Yojson.Safe.Util.to_string);
    check string "same original trace" "original-trace"
      (field "trace_id" row |> Yojson.Safe.Util.to_string);
    check string "actual parsing invocation" (Artifact_id.to_string invocation_id)
      (field "invocation_id" row |> Yojson.Safe.Util.to_string);
    let id = field "evidence_id" row |> Yojson.Safe.Util.to_string in
    check bool "public result identifies only its committed evidence" true
      (List.exists (fun detail -> String_util.contains_substring detail id) details)) rows;
  check (list int) "actual candidate ordinals survive" [0;1]
    (List.map (fun (_,row)->field "attempt_index" row |> Yojson.Safe.Util.to_int) rows
     |> List.sort Int.compare);
  List.iter (fun detail -> check bool "private bytes absent from public errors" false
    (String.contains detail '~')) details
;;

let test_failed_storage_does_not_invent_evidence () =
  let base_path = Filename.temp_file "evidence-unwritable-base-" "" in
  Fun.protect ~finally:(fun ()->Sys.remove base_path) @@ fun () ->
  let error = Error.structured_output_parse_error ~reason:Invalid_json
    ~detail:"~private-detail~" ~raw:"~private-output~" in
  let before = (Log.Ring.bounds ()).total in
  let result = Evidence.record_failure ~base_path:(Some base_path)
    ~attempt:(attempt (Evidence.invocation_id ()) 0) error in
  check bool "failed storage is explicitly unavailable" true
    (String_util.contains_substring result "structured_evidence_unavailable: write_failed");
  check bool "no committed reference is fabricated" false
    (String_util.contains_substring result "structured_evidence_id:");
  check bool "no inline raw fallback" false (String.contains result '~');
  let entries = Log.Ring.recent ~since_seq:(before - 1) () in
  check bool "storage failure creates an opaque observation" true
    (List.exists (fun (entry:Log.Ring.entry) ->
      String_util.contains_substring entry.message "structured_evidence_write_failed") entries);
  List.iter (fun (entry:Log.Ring.entry) ->
    check bool "public log ring does not expose the private workspace path" false
      (String_util.contains_substring entry.message base_path)) entries
;;

let test_missing_workspace_does_not_use_ambient_root () =
  let error = Error.structured_output_parse_error ~reason:Schema_rejected
    ~detail:"~private-key~" ~raw:"~private-output~" in
  let result = Evidence.record_failure ~base_path:None
    ~attempt:(attempt (Evidence.invocation_id ()) 0) error in
  check bool "missing root is explicit" true
    (String_util.contains_substring result "workspace_not_supplied");
  check bool "private evidence is not public" false (String.contains result '~')
;;

let test_actual_judge_parser_retains_original_failure_and_usage () = with_workspace @@ fun base_path ->
  let invocation_id = Evidence.invocation_id () in
  let usage : Fusion_types.usage = { input_tokens=17; output_tokens=9 } in
  List.iteri (fun index raw ->
    let record_invalid error = Evidence.record_failure ~base_path:(Some base_path)
      ~attempt:{(attempt invocation_id index) with source=Fusion_judge;
        tool_use_id=None; trace_id=None} error in
    match Fusion_judge.For_testing.parse_response ~record_invalid raw usage with
    | Error (Fusion_types.Parse_error detail, observed_usage) ->
      check int "failed judge input usage survives" usage.input_tokens observed_usage.input_tokens;
      check int "failed judge output usage survives" usage.output_tokens observed_usage.output_tokens;
      check bool "private parser and response text stay private" false (String.contains detail '~')
    | Error ((Timeout | Provider_error _ | Empty_response _ | Empty_result
        | Build_error _ | Panels_unavailable _ | Unknown_route _
        | Route_unavailable _ | Internal_error _), _)
    | Ok _ -> fail "invalid received output must remain a typed parse failure")
    ["~private-broken-json~"; "```json\n{\"~private-schema-key~\":true}\n```"];
  let rows = records base_path |> List.map snd in
  check int "both actual failed candidates retained" 2 (List.length rows);
  check (list string) "closed syntax/schema classification" ["invalid_json";"schema_rejected"]
    (List.map (fun row ->field "reason" row |> Yojson.Safe.Util.to_string) rows |> List.sort String.compare);
  check bool "fenced original evidence precedes parser normalization" true
    (List.exists (fun row ->field "raw_preview" row
       = `String "```json\n{\"~private-schema-key~\":true}\n```") rows)
;;

let test_valid_judge_response_creates_no_failure_evidence () =
  let called = ref false in
  let record_invalid _ = called:=true; fail "valid output cannot record a parse failure" in
  let raw = {|{"resolved_answer":"original answer","decision":{"kind":"answer","answer":"yes"}}|} in
  match Fusion_judge.For_testing.parse_response ~record_invalid raw Fusion_types.zero_usage with
  | Ok (answer,_) ->
    check string "original valid answer" "original answer" answer.resolved_answer;
    check bool "no fabricated failed attempt" false !called
  | Error _ -> fail "valid judge response must still succeed"
;;

let () = run "structured response evidence"
  ["private response evidence",[
    test_case "actual bounded error keeps each candidate and parent" `Quick
      test_actual_bounded_error_survives_distinct_attempts;
    test_case "storage failure keeps failure without a reference" `Quick
      test_failed_storage_does_not_invent_evidence;
    test_case "missing workspace is not an ambient write" `Quick
      test_missing_workspace_does_not_use_ambient_root;
    test_case "actual judge failures keep raw bytes and consumed usage" `Quick
      test_actual_judge_parser_retains_original_failure_and_usage;
    test_case "valid judge creates no failure evidence" `Quick
      test_valid_judge_response_creates_no_failure_evidence]]
