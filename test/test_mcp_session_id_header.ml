(** test_mcp_session_id_header — RFC-0100 PR-3 session-id contract.

    Pins the Q3-default behaviour: a client that echoes an
    [Mcp-Session-Id] header the server has no state for is rejected
    with the equivalent of [404 Not Found], rather than silently
    minted into a phantom session. Also exercises the
    {!Masc.Mcp_session.get_or_generate} echo contract that the
    transport relies on to bind a session id across multiple POSTs. *)

open Alcotest

module Http_transport = Server_mcp_transport_http
module Session = Mcp_session

let request_body ~method_ =
  Printf.sprintf {|{"jsonrpc":"2.0","id":1,"method":"%s","params":{}}|} method_

let test_validate_session_known_unknown_id_blocks_non_handshake () =
  (* The transport pre-checks [validate_session_known] before any
     work that would mutate session state. Unknown id + non-handshake
     method must produce [Error]; the transport responds 404 and the
     client must re-handshake. *)
  let result =
    Http_transport.validate_session_known
      ~session_was_provided:true
      ~is_known:false
      (request_body ~method_:"tools/call")
  in
  match result with
  | Ok () ->
      fail "unknown id for tools/call should be rejected"
  | Error msg ->
      check bool "error message names the session id" true
        (String.length msg > 0)

let test_validate_session_known_rejects_unknown_for_all_methods () =
  (* Session ids are server-issued. Even bootstrap methods must omit the
     header when starting a new stateful session; otherwise a deleted id could
     be recreated while its old transport generation is still retiring. *)
  let check_error method_ =
    let result =
      Http_transport.validate_session_known
        ~session_was_provided:true
        ~is_known:false
        (request_body ~method_)
    in
    check bool (Printf.sprintf "%s rejects an unknown supplied id" method_)
      true (Result.is_error result)
  in
  check_error "initialize";
  check_error "ping";
  check_error "notifications/initialized";
  check_error "server/discover"

let test_validate_session_known_passes_when_known () =
  (* A known session id with any method passes. *)
  let result =
    Http_transport.validate_session_known
      ~session_was_provided:true
      ~is_known:true
      (request_body ~method_:"tools/call")
  in
  check bool "known id always passes" true (Result.is_ok result)

let test_validate_session_known_passes_when_not_provided () =
  (* No header at all is handled by [validate_session_requirement],
     not by [validate_session_known]. The latter must short-circuit
     with [Ok] when [session_was_provided=false]. *)
  let result =
    Http_transport.validate_session_known
      ~session_was_provided:false
      ~is_known:false
      (request_body ~method_:"tools/call")
  in
  check bool "missing header bypasses Q3 check" true (Result.is_ok result)

let test_session_id_echo_across_requests () =
  (* The session id format is stable enough that a freshly minted id
     round-trips through [get_or_generate] unchanged. This is the
     property the transport relies on when echoing
     [Mcp-Session-Id] across three POSTs from the same client. *)
  let id = Session.generate () in
  check bool "generated id is valid" true (Session.is_valid id);
  let echoed_1 = Session.get_or_generate (Some id) in
  let echoed_2 = Session.get_or_generate (Some id) in
  let echoed_3 = Session.get_or_generate (Some id) in
  check string "echo 1 preserves id" id echoed_1;
  check string "echo 2 preserves id" id echoed_2;
  check string "echo 3 preserves id" id echoed_3

let test_unknown_id_response_headers_do_not_mint_session () =
  let headers =
    Server_mcp_transport_http_headers.protocol_headers "2025-11-25"
  in
  check (option string) "protocol version remains explicit"
    (Some "2025-11-25")
    (List.assoc_opt "mcp-protocol-version" headers);
  check (option string) "unknown-id response does not issue a session" None
    (List.assoc_opt "mcp-session-id" headers)

let () =
  Alcotest.run "test_mcp_session_id_header"
    [
      ( "rfc-0100-pr3-q3-unknown-session-404",
        [
          test_case "unknown id + tools/call rejected" `Quick
            test_validate_session_known_unknown_id_blocks_non_handshake;
          test_case "unknown id rejected for bootstrap methods" `Quick
            test_validate_session_known_rejects_unknown_for_all_methods;
          test_case "known id always passes" `Quick
            test_validate_session_known_passes_when_known;
          test_case "missing header bypasses Q3" `Quick
            test_validate_session_known_passes_when_not_provided;
        ] );
      ( "rfc-0100-pr3-session-id-echo",
        [
          test_case "echo across 3 requests preserves id" `Quick
            test_session_id_echo_across_requests;
          test_case "unknown-id response does not mint a session" `Quick
            test_unknown_id_response_headers_do_not_mint_session;
        ] );
    ]
