let request_id json =
  match Mcp_transport_protocol.request_id_of_yojson json with
  | Ok value -> value
  | Error error ->
    Alcotest.fail (Mcp_transport_protocol.request_id_error_to_string error)
;;

let identity () =
  match
    Tool_invocation_ref.external_mcp
      ~request_id:(request_id (`Intlit "9007199254740993"))
      ~session_id:"session-1"
  with
  | Ok value -> value
  | Error error -> Alcotest.fail (Tool_invocation_ref.error_to_string error)
;;

let test_roundtrip () =
  let expected = identity () in
  match Tool_invocation_ref.of_yojson (Tool_invocation_ref.to_yojson expected) with
  | Ok actual ->
    Alcotest.(check bool)
      "exact identity"
      true
      (Tool_invocation_ref.equal expected actual)
  | Error error ->
    Alcotest.fail (Tool_invocation_ref.decode_error_to_string error)
;;

let test_closed_decoder () =
  let canonical = Tool_invocation_ref.to_yojson (identity ()) in
  let fields =
    match canonical with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "canonical identity must be an object"
  in
  let check label expected json =
    match Tool_invocation_ref.of_yojson json with
    | Error actual -> Alcotest.(check bool) label true (actual = expected)
    | Ok _ -> Alcotest.failf "%s: malformed identity decoded" label
  in
  check
    "unknown"
    (Tool_invocation_ref.Unknown_field "extra")
    (`Assoc (("extra", `Null) :: fields));
  check
    "duplicate"
    (Tool_invocation_ref.Duplicate_field "source")
    (`Assoc (("source", `String "external_mcp") :: fields));
  check
    "missing"
    (Tool_invocation_ref.Missing_field "request_id")
    (`Assoc (List.remove_assoc "request_id" fields));
  check
    "source"
    (Tool_invocation_ref.Invalid_source "invented")
    (`Assoc
      (("source", `String "invented") :: List.remove_assoc "source" fields));
  check
    "source type"
    (Tool_invocation_ref.Expected_string "source")
    (`Assoc (("source", `Null) :: List.remove_assoc "source" fields));
  check
    "request id"
    (Tool_invocation_ref.Invalid_request_id
       Mcp_transport_protocol.Null_request_id)
    (`Assoc (("request_id", `Null) :: List.remove_assoc "request_id" fields));
  check
    "session"
    (Tool_invocation_ref.Invalid_identity
       Tool_invocation_ref.Empty_mcp_session_id)
    (`Assoc (("session_id", `String " ") :: List.remove_assoc "session_id" fields));
  check
    "session type"
    (Tool_invocation_ref.Expected_string "session_id")
    (`Assoc (("session_id", `Null) :: List.remove_assoc "session_id" fields))
;;

let () =
  Alcotest.run
    "tool invocation ref"
    [ ( "codec"
      , [ Alcotest.test_case "roundtrip" `Quick test_roundtrip
        ; Alcotest.test_case "closed decoder" `Quick test_closed_decoder
        ] )
    ]
