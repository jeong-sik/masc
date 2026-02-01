(** Tests for Message_schema module *)

module MS = Masc_mcp.Message_schema

let test_freeform_roundtrip () =
  let msg = MS.Freeform "hello world" in
  match MS.roundtrip msg with
  | Ok result ->
      Alcotest.(check bool) "freeform roundtrip" true
        (MS.equal_structured_message msg result)
  | Error e -> Alcotest.fail e

let test_task_update_roundtrip () =
  let msg = MS.TaskUpdate {
    task_id = "task-001";
    status = "done";
    payload = Some (`Assoc [("key", `String "value")]);
  } in
  match MS.roundtrip msg with
  | Ok result ->
      Alcotest.(check bool) "task_update roundtrip" true
        (MS.equal_structured_message msg result)
  | Error e -> Alcotest.fail e

let test_task_update_no_payload () =
  let msg = MS.TaskUpdate {
    task_id = "task-002";
    status = "in_progress";
    payload = None;
  } in
  match MS.roundtrip msg with
  | Ok result ->
      Alcotest.(check bool) "task_update no payload" true
        (MS.equal_structured_message msg result)
  | Error e -> Alcotest.fail e

let test_status_report_roundtrip () =
  let msg = MS.StatusReport {
    agent = "claude";
    progress = 0.75;
    details = "Processing step 3 of 4";
  } in
  match MS.roundtrip msg with
  | Ok result ->
      Alcotest.(check bool) "status_report roundtrip" true
        (MS.equal_structured_message msg result)
  | Error e -> Alcotest.fail e

let test_request_roundtrip () =
  let msg = MS.Request {
    target = "codex";
    action = "review";
    params = `Assoc [("file", `String "main.ml")];
  } in
  match MS.roundtrip msg with
  | Ok result ->
      Alcotest.(check bool) "request roundtrip" true
        (MS.equal_structured_message msg result)
  | Error e -> Alcotest.fail e

let test_response_roundtrip () =
  let msg = MS.Response {
    request_id = "req-123";
    success = true;
    result = `String "LGTM";
  } in
  match MS.roundtrip msg with
  | Ok result ->
      Alcotest.(check bool) "response roundtrip" true
        (MS.equal_structured_message msg result)
  | Error e -> Alcotest.fail e

(* Validation mode tests *)

let test_permissive_accepts_plain_text () =
  match MS.validate ~mode:Permissive "just a plain string" with
  | Ok (Freeform text) ->
      Alcotest.(check string) "plain text preserved" "just a plain string" text
  | Ok _ -> Alcotest.fail "expected Freeform"
  | Error e -> Alcotest.fail e

let test_permissive_accepts_bad_json () =
  match MS.validate ~mode:Permissive "{\"unknown\": true}" with
  | Ok (Freeform _) -> () (* ok, wrapped as freeform *)
  | Ok _ -> Alcotest.fail "expected Freeform for unknown JSON"
  | Error e -> Alcotest.fail e

let test_strict_rejects_plain_text () =
  match MS.validate ~mode:Strict "not json" with
  | Error _ -> () (* expected *)
  | Ok _ -> Alcotest.fail "strict should reject non-JSON"

let test_strict_rejects_bad_schema () =
  let bad = Yojson.Safe.to_string (`Assoc [("type", `String "task_update")]) in
  match MS.validate ~mode:Strict bad with
  | Error _ -> () (* missing required fields *)
  | Ok _ -> Alcotest.fail "strict should reject invalid schema"

let test_strict_accepts_valid_structured () =
  let valid = Yojson.Safe.to_string (`Assoc [
    ("type", `String "task_update");
    ("task_id", `String "t-1");
    ("status", `String "done");
  ]) in
  match MS.validate ~mode:Strict valid with
  | Ok (TaskUpdate { task_id; status; _ }) ->
      Alcotest.(check string) "task_id" "t-1" task_id;
      Alcotest.(check string) "status" "done" status
  | Ok _ -> Alcotest.fail "expected TaskUpdate"
  | Error e -> Alcotest.fail e

let test_warn_wraps_invalid () =
  match MS.validate ~mode:Warn "plain text message" with
  | Ok (Freeform _) -> ()
  | Ok _ -> Alcotest.fail "expected Freeform"
  | Error _ -> Alcotest.fail "warn should not reject"

(* Utility tests *)

let test_message_type_string () =
  Alcotest.(check string) "task_update" "task_update"
    (MS.message_type_string
       (TaskUpdate { task_id = "t"; status = "s"; payload = None }));
  Alcotest.(check string) "freeform" "freeform"
    (MS.message_type_string (Freeform "hello"))

let test_is_targeted_at () =
  let msg = MS.Request {
    target = "codex";
    action = "review";
    params = `Null;
  } in
  Alcotest.(check bool) "targeted at codex" true
    (MS.is_targeted_at "codex" msg);
  Alcotest.(check bool) "not targeted at claude" false
    (MS.is_targeted_at "claude" msg);
  Alcotest.(check bool) "freeform not targeted" false
    (MS.is_targeted_at "anyone" (Freeform "hello"))

let test_validation_mode_conversion () =
  Alcotest.(check string) "strict" "strict"
    (MS.validation_mode_to_string Strict);
  Alcotest.(check bool) "roundtrip strict" true
    (MS.Strict = MS.validation_mode_of_string "strict");
  Alcotest.(check bool) "roundtrip warn" true
    (MS.Warn = MS.validation_mode_of_string "warn");
  Alcotest.(check bool) "unknown -> permissive" true
    (MS.Permissive = MS.validation_mode_of_string "whatever")

(* of_json edge cases *)

let test_of_json_unknown_type () =
  let json = `Assoc [("type", `String "banana")] in
  match MS.of_json json with
  | Error msg ->
      Alcotest.(check bool) "mentions unknown type" true
        (String.length msg > 0)
  | Ok _ -> Alcotest.fail "should reject unknown type"

let test_of_json_missing_type () =
  let json = `Assoc [("foo", `String "bar")] in
  match MS.of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should reject missing type"

let () =
  Alcotest.run "Message_schema" [
    "roundtrip", [
      Alcotest.test_case "freeform" `Quick test_freeform_roundtrip;
      Alcotest.test_case "task_update" `Quick test_task_update_roundtrip;
      Alcotest.test_case "task_update no payload" `Quick test_task_update_no_payload;
      Alcotest.test_case "status_report" `Quick test_status_report_roundtrip;
      Alcotest.test_case "request" `Quick test_request_roundtrip;
      Alcotest.test_case "response" `Quick test_response_roundtrip;
    ];
    "validation", [
      Alcotest.test_case "permissive: plain text" `Quick test_permissive_accepts_plain_text;
      Alcotest.test_case "permissive: bad json" `Quick test_permissive_accepts_bad_json;
      Alcotest.test_case "strict: rejects plain text" `Quick test_strict_rejects_plain_text;
      Alcotest.test_case "strict: rejects bad schema" `Quick test_strict_rejects_bad_schema;
      Alcotest.test_case "strict: accepts valid" `Quick test_strict_accepts_valid_structured;
      Alcotest.test_case "warn: wraps invalid" `Quick test_warn_wraps_invalid;
    ];
    "utilities", [
      Alcotest.test_case "message_type_string" `Quick test_message_type_string;
      Alcotest.test_case "is_targeted_at" `Quick test_is_targeted_at;
      Alcotest.test_case "validation_mode conversion" `Quick test_validation_mode_conversion;
    ];
    "edge_cases", [
      Alcotest.test_case "unknown type" `Quick test_of_json_unknown_type;
      Alcotest.test_case "missing type" `Quick test_of_json_missing_type;
    ];
  ]
