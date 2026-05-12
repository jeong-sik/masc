open Alcotest
open Masc_mcp

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
  let json = Yojson.Safe.from_string (Tool_args.error_response_with fields) in
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

let () =
  run ~and_exit:false "Tool_args_envelope"
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
        ] );
    ]
