open Alcotest
open Masc

let parse_json label payload =
  try Yojson.Safe.from_string payload with
  | exn -> failf "%s was not valid JSON: %s; payload=%s" label (Printexc.to_string exn) payload

let test_error_response_matches_error_assoc () =
  let msg = "boom" in
  let expected =
    Yojson.Safe.to_string (Tool_args.error_assoc [ ("message", `String msg) ])
  in
  check string
    "error_response delegates to error_assoc"
    expected
    (Tool_args.error_response msg)

let test_error_response_with_matches_error_assoc () =
  let fields =
    [ ("agent_id", `String "agent-1"); ("config_path", `String "/tmp/cfg") ]
  in
  let expected = Yojson.Safe.to_string (Tool_args.error_assoc fields) in
  check string
    "error_response_with delegates to error_assoc"
    expected
    (Tool_args.error_response_with fields)

let test_error_response_with_prepends_status_first () =
  let fields = [ ("message", `String "oops") ] in
  let json = parse_json "error_response_with" (Tool_args.error_response_with fields) in
  match json with
  | `Assoc ((k, `String v) :: _) ->
    check string "first key is status" "status" k;
    check string "status value" "error" v
  | _ -> fail "expected assoc with status first"

let test_error_response_typed_path () =
  let actual = Tool_args.error_response_typed ~code:Validation_error "invalid" in
  let expected =
    Tool_args.error_response_with
      [
        ("error_code", `String "validation_error");
        ("message", `String "invalid");
      ]
  in
  check string "typed error path uses canonical helper" expected actual

let test_error_response_with_drops_caller_status () =
  let json =
    parse_json
      "error_response_with duplicate status"
      (Tool_args.error_response_with
         [ ("status", `String "ok"); ("message", `String "boom") ])
  in
  match json with
  | `Assoc fields ->
    check
      (list string)
      "single canonical status key"
      [ "status"; "message" ]
      (List.map fst fields);
    check string "status value" "error"
      (Yojson.Safe.Util.(json |> member "status" |> to_string))
  | _ -> fail "expected assoc"

let test_ok_assoc_drops_caller_status () =
  match Tool_args.ok_assoc [ ("status", `String "error"); ("value", `Int 1) ] with
  | `Assoc fields ->
    check
      (list string)
      "single canonical status key"
      [ "status"; "value" ]
      (List.map fst fields);
    check string "status value" "ok"
      (Yojson.Safe.Util.(`Assoc fields |> member "status" |> to_string))
  | _ -> fail "expected assoc"

(* The class of every code, pinned. A code added later is caught by the
   exhaustive match in [failure_class_of_error_code], not by this list. *)
let test_failure_class_of_every_error_code () =
  let expected : (Tool_args.error_code * string) list =
    [ Tool_args.Validation_error, "policy_rejection"
    ; Tool_args.Not_found, "policy_rejection"
    ; Tool_args.Auth_required, "policy_rejection"
    ; Tool_args.Permission_denied, "policy_rejection"
    ; Tool_args.Conflict, "workflow_rejection"
    ; Tool_args.Precondition_failed, "workflow_rejection"
    ; Tool_args.Rate_limited, "dependency_unavailable"
    ; Tool_args.Timeout, "dependency_unavailable"
    ; Tool_args.External_service_unavailable, "dependency_unavailable"
    ; Tool_args.Unavailable, "dependency_unavailable"
    ; Tool_args.Internal_error, "runtime_failure"
    ; Tool_args.Not_implemented, "runtime_failure"
    ]
  in
  List.iter
    (fun (code, class_) ->
      check string
        (Tool_args.error_code_to_string code)
        class_
        (Tool_result.tool_failure_class_to_string
           (Tool_args.failure_class_of_error_code code)))
    expected

(* The envelope's error_code and the result's class come from one value. *)
let test_typed_results_take_the_class_of_their_code () =
  let class_of result =
    Option.map Tool_result.tool_failure_class_to_string (Tool_result.failure_class result)
  in
  check (option string) "a validation error is the caller's to fix"
    (Some "policy_rejection")
    (class_of (Tool_args.error_result_typed ~start_time:(Tool_timing.start ()) ~code:Tool_args.Validation_error "bad"));
  check (option string) "a conflict is the state's"
    (Some "workflow_rejection")
    (class_of (Tool_args.error_result_typed ~start_time:(Tool_timing.start ()) ~code:Tool_args.Conflict "moved"));
  check (option string) "field errors are the caller's to fix"
    (Some "policy_rejection")
    (class_of
       (Tool_args.validation_error_result
          ~start_time:(Tool_timing.start ())
          [ { Tool_args.field = "action"
            ; constraint_violated = Tool_args.Required
            ; message = "action is required"
            ; expected = Some "string"
            ; received = None
            }
          ]))

let () =
  run "Tool_args_envelope"
    [
      ( "error_envelope",
        [
          test_case "error_response delegates" `Quick
            test_error_response_matches_error_assoc;
          test_case "error_response_with delegates" `Quick
            test_error_response_with_matches_error_assoc;
          test_case "status field prepended first" `Quick
            test_error_response_with_prepends_status_first;
          test_case "typed path keeps canonical shape" `Quick
            test_error_response_typed_path;
          test_case "caller status cannot override error envelope" `Quick
            test_error_response_with_drops_caller_status;
          test_case "caller status cannot override ok envelope" `Quick
            test_ok_assoc_drops_caller_status;
        ] );
      ( "failure_class",
        [
          test_case "every error code has one class" `Quick
            test_failure_class_of_every_error_code;
          test_case "typed results take the class of their code" `Quick
            test_typed_results_take_the_class_of_their_code;
        ] );
    ]
