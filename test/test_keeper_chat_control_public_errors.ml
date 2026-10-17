open Alcotest

module Public = Server_keeper_chat_public_error
module Control = Server_routes_http_keeper_stream.For_testing

let secret = "orchid river seventy nine"
let base_path = "/private/keeper-runtime"
let diagnostic = "provider failure: " ^ secret ^ " at " ^ base_path ^ "/error.trace"

let contains = String_util.contains_substring
let member key json = Yojson.Safe.Util.member key json

let check_private_absent body =
  let wire = Yojson.Safe.to_string body in
  List.iter (fun text ->
    check bool "private diagnostic stays out of reply" false (contains wire text))
    [secret; base_path; diagnostic]

let private_failure kind =
  let before = (Log.Ring.bounds ()).total in
  let error = Control.control_public_error kind diagnostic in
  let entries = Log.Ring.recent ~since_seq:(before - 1) () in
  check int "one diagnostic incident" 1 (List.length entries);
  let entry = List.hd entries in
  check bool "operator keeps original diagnostic" true
    (contains entry.message diagnostic);
  check bool "same incident correlates public and private facts" true
    (contains entry.message error.Public.incident_id);
  check bool "incident is server generated" true
    (String.length error.incident_id > 0 && error.incident_id <> diagnostic);
  error

let test_priority_keeps_queue_effect_when_interrupt_fails () =
  let error = private_failure Public.Interrupt_failed in
  let body = Public.prioritized_operation_json ~request_id:"actual-operation-7"
      ~signalled:false ~interrupt_error:(Some error) in
  check bool "priority was applied" true
    (Yojson.Safe.Util.to_bool (member "prioritized" body));
  check bool "no cancellation is invented" false
    (Yojson.Safe.Util.to_bool (member "signalled" body));
  check string "same actual request" "actual-operation-7"
    (Yojson.Safe.Util.to_string (member "request_id" body));
  check string "fixed safe detail" "The active turn could not be interrupted."
    (Yojson.Safe.Util.to_string (member "detail" body));
  check string "owned failure code" "interrupt_failed"
    (Yojson.Safe.Util.to_string (member "error_code" body));
  check string "same actual diagnostic incident" error.incident_id
    (Yojson.Safe.Util.to_string (member "incident_id" body));
  check_private_absent body

let test_interrupt_failure_fields_are_safe () =
  let error = private_failure Public.Interrupt_failed in
  let body = `Assoc
      (["signalled", `Bool false; "reason", `String "cancel_failed";
        "turn_id", `Int 7] @ Public.failure_fields error) in
  check string "actual refusal reason retained" "cancel_failed"
    (Yojson.Safe.Util.to_string (member "reason" body));
  check int "actual turn identity retained" 7
    (Yojson.Safe.Util.to_int (member "turn_id" body));
  check string "same diagnostic incident" error.incident_id
    (Yojson.Safe.Util.to_string (member "incident_id" body));
  check_private_absent body

let test_healthy_priority_has_no_error_incident () =
  let before = (Log.Ring.bounds ()).total in
  List.iter (fun signalled ->
    let body = Public.prioritized_operation_json ~request_id:"actual-operation-7"
        ~signalled ~interrupt_error:None in
    check bool "actual signal effect preserved" signalled
      (Yojson.Safe.Util.to_bool (member "signalled" body));
    match body with
    | `Assoc fields ->
      check bool "no failure code without failure" false (List.mem_assoc "error_code" fields);
      check bool "no fabricated incident" false (List.mem_assoc "incident_id" fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
    | `List _ -> fail "expected public response object")
    [false; true];
  check int "healthy control emits no failure log" before (Log.Ring.bounds ()).total

let test_non_success_error_retains_only_public_facts () =
  List.iter (fun (kind, status, code) ->
    let error = private_failure kind in
    check bool "owned HTTP status" true (error.Public.status = status);
    let body = Public.to_json error in
    check string "owned public code" code
      (Yojson.Safe.Util.to_string (member "error" body));
    check string "public/private correlation" error.incident_id
      (Yojson.Safe.Util.to_string (member "incident_id" body));
    check_private_absent body)
    [Public.Invalid_input, `Bad_request, "invalid_input";
     Public.Store_unavailable, `Service_unavailable, "store_unavailable"]

let () = run "Keeper public control replies"
    ["public replies", [
      test_case "queue effect survives interruption failure" `Quick
        test_priority_keeps_queue_effect_when_interrupt_fails;
      test_case "interrupt refusal fields retain only public facts" `Quick
        test_interrupt_failure_fields_are_safe;
      test_case "healthy priority has no error incident" `Quick
        test_healthy_priority_has_no_error_incident;
      test_case "non-success response retains only public facts" `Quick
        test_non_success_error_retains_only_public_facts]]
