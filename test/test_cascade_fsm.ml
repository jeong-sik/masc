(** Focused tests for cascade FSM user-facing error rendering. *)

open Masc_mcp

let check_string = Alcotest.(check string)

let test_to_user_message_preserves_http_detail () =
  let err =
    Llm_provider.Http_client.HttpError
      { code = 502; body = "bad gateway from provider" }
  in
  check_string
    "http detail"
    "HTTP 502: bad gateway from provider"
    (Cascade_fsm.to_user_message (Some err))

let test_format_exhausted_error_wraps_user_message () =
  let err =
    Llm_provider.Http_client.HttpError
      { code = 502; body = "bad gateway from provider" }
  in
  match Cascade_fsm.format_exhausted_error (Some err) with
  | Llm_provider.Http_client.NetworkError { message; kind } ->
      check_string
        "wrapper"
        "All models failed: HTTP 502: bad gateway from provider"
        message;
      Alcotest.(check bool) "kind defaults unknown" true
        (kind = Llm_provider.Http_client.Unknown)
  | _ -> Alcotest.fail "expected NetworkError wrapper"

let test_accept_rejected_preserves_error_variant () =
  let err =
    Llm_provider.Http_client.AcceptRejected
      { reason = "accept predicate rejected empty response" }
  in
  check_string
    "accept detail"
    "accept predicate rejected empty response"
    (Cascade_fsm.to_user_message (Some err));
  match Cascade_fsm.format_exhausted_error (Some err) with
  | Llm_provider.Http_client.AcceptRejected { reason } ->
      check_string
        "accept rejected remains terminal accept detail"
        "accept predicate rejected empty response"
        reason
  | _ -> Alcotest.fail "expected AcceptRejected to stay unwrapped"

let test_none_message_is_explicit () =
  check_string
    "none detail"
    "No providers available"
    (Cascade_fsm.to_user_message None)

let () =
  Alcotest.run "Cascade_fsm"
    [
      ( "user_message",
        [
          Alcotest.test_case
            "http detail"
            `Quick
            test_to_user_message_preserves_http_detail;
          Alcotest.test_case
            "exhaustion wrapper"
            `Quick
            test_format_exhausted_error_wraps_user_message;
          Alcotest.test_case
            "accept rejected preserved"
            `Quick
            test_accept_rejected_preserves_error_variant;
          Alcotest.test_case
            "none detail"
            `Quick
            test_none_message_is_explicit;
        ] );
    ]
