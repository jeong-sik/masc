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

let test_typed_error_codes_select_failure_classes () =
  let case code expected =
    Tool_args.failure_class_of_error_code code
    |> Tool_result.tool_failure_class_to_string
    |> check string (Tool_args.error_code_to_string code) expected
  in
  case Validation_error "policy_rejection";
  case Conflict "workflow_rejection";
  case Timeout "transient_error";
  case Internal_error "runtime_failure"
;;

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
          test_case "typed codes select failure classes" `Quick
            test_typed_error_codes_select_failure_classes;
        ] );
    ]
