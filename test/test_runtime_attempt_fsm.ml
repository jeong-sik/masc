(** Unit tests for Runtime_attempt_fsm's lossless observation renderers. *)

open Runtime_attempt_fsm

let mk_http_err ?(code = 429) ?(body = "") () =
  Llm_provider.Http_client.HttpError { code; body; retry_after_header = None }

let mk_network_err ?(message = "net err") () =
  Llm_provider.Http_client.NetworkError
    { message; kind = Llm_provider.Http_client.Unknown }

let mk_accept_rejected ?(reason = "quality") () =
  Llm_provider.Http_client.AcceptRejected { reason }

(* --- to_user_message (live: keeper_turn_driver_try_runtime) --- *)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let test_user_message_http () =
  let msg = to_user_message (Some (mk_http_err ~code:503 ~body:"overloaded" ())) in
  Alcotest.(check bool) "mentions HTTP 503" true (contains ~needle:"503" msg)

let test_user_message_accept_rejected () =
  let msg = to_user_message (Some (mk_accept_rejected ~reason:"low quality" ())) in
  Alcotest.(check string) "reason passes through" "low quality" msg

let test_user_message_network () =
  let msg = to_user_message (Some (mk_network_err ~message:"conn reset" ())) in
  Alcotest.(check string) "network message passes through" "conn reset" msg

let test_user_message_none () =
  Alcotest.(check bool) "absent error still yields a message" true
    (String.length (to_user_message None) > 0)

(* --- provider_outcome_to_string --- *)

let test_outcome_to_string_call_err () =
  Alcotest.(check bool) "Call_err serializes non-empty" true
    (String.length (provider_outcome_to_string (Call_err (mk_http_err ()))) > 0)

let test_outcome_option_to_string_none () =
  Alcotest.(check bool) "None serializes non-empty" true
    (String.length (provider_outcome_option_to_string None) > 0)

let () =
  Alcotest.run "runtime_attempt_fsm"
    [ ( "to_user_message"
      , [ Alcotest.test_case "HTTP 503" `Quick test_user_message_http
        ; Alcotest.test_case "accept rejected reason" `Quick
            test_user_message_accept_rejected
        ; Alcotest.test_case "network message" `Quick test_user_message_network
        ; Alcotest.test_case "none" `Quick test_user_message_none
        ] )
    ; ( "provider_outcome_to_string"
      , [ Alcotest.test_case "Call_err" `Quick test_outcome_to_string_call_err
        ; Alcotest.test_case "option none" `Quick
            test_outcome_option_to_string_none
        ] )
    ]
