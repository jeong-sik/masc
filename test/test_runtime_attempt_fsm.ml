(** Unit tests for Runtime_attempt_fsm.

    Covers the functions with production callers first ([should_try_next],
    [to_user_message], [provider_outcome_to_string]) and documents the pure
    [decide] matrix.  Only [Call_err]/[Accept_rejected]-reachable paths are
    exercised: constructing the opaque [Llm_provider.Types.api_response]
    needed for [Call_ok] is not possible from this test. *)

open Runtime_attempt_fsm

let mk_http_err ?(code = 429) ?(body = "") () =
  Llm_provider.Http_client.HttpError { code; body }

let mk_network_err ?(message = "net err") () =
  Llm_provider.Http_client.NetworkError
    { message; kind = Llm_provider.Http_client.Unknown }

let mk_timeout_err ?(message = "timeout") () =
  Llm_provider.Http_client.TimeoutError
    { message; phase = Llm_provider.Http_client.Wall_clock }

let mk_provider_terminal ?(message = "terminal") () =
  Llm_provider.Http_client.ProviderTerminal
    { kind = Llm_provider.Http_client.Other "test_terminal"; message }

let mk_accept_rejected ?(reason = "quality") () =
  Llm_provider.Http_client.AcceptRejected { reason }

(* --- should_try_next (live: keeper_turn_driver_try_runtime) --- *)

let check_retry name expected err =
  Alcotest.(check bool) name expected (should_try_next err)

let test_should_try_http_408 () = check_retry "408 retries" true (mk_http_err ~code:408 ())
let test_should_try_http_409 () = check_retry "409 retries" true (mk_http_err ~code:409 ())
let test_should_try_http_429 () = check_retry "429 retries" true (mk_http_err ~code:429 ())
let test_should_try_http_500 () = check_retry "500 retries" true (mk_http_err ~code:500 ())
let test_should_try_http_400 () = check_retry "400 stops" false (mk_http_err ~code:400 ())
let test_should_try_http_404 () = check_retry "404 stops" false (mk_http_err ~code:404 ())
let test_should_try_network () = check_retry "network retries" true (mk_network_err ())
let test_should_try_timeout () = check_retry "timeout retries" true (mk_timeout_err ())

let test_should_try_terminal () =
  check_retry "provider terminal stops" false (mk_provider_terminal ())

let test_should_try_accept_rejected () =
  check_retry "accept rejection stops" false (mk_accept_rejected ())

(* --- decide: Call_err / Accept_rejected matrix --- *)

let test_decide_call_err_retryable_not_last () =
  match
    decide ~accept_on_exhaustion:false ~is_last:false
      (Call_err (mk_http_err ~code:429 ()))
  with
  | Try_next { last_err = Some _ } -> ()
  | _ -> Alcotest.fail "retryable + not-last should yield Try_next with last_err"

let test_decide_call_err_retryable_last () =
  match
    decide ~accept_on_exhaustion:false ~is_last:true
      (Call_err (mk_http_err ~code:429 ()))
  with
  | Exhausted { last_err = Some _ } -> ()
  | _ -> Alcotest.fail "retryable + last should yield Exhausted with last_err"

let test_decide_call_err_terminal_not_last () =
  match
    decide ~accept_on_exhaustion:false ~is_last:false
      (Call_err (mk_provider_terminal ()))
  with
  | Exhausted { last_err = Some _ } -> ()
  | _ -> Alcotest.fail "non-retryable error should yield Exhausted even when not last"

let test_decide_accept_rejected_not_last () =
  (* Accept_rejected carries a response we cannot construct; route the same
     error shape through Call_err to pin the retry classification instead. *)
  match
    decide ~accept_on_exhaustion:false ~is_last:false
      (Call_err (mk_accept_rejected ()))
  with
  | Exhausted { last_err = Some (Llm_provider.Http_client.AcceptRejected _) } -> ()
  | _ -> Alcotest.fail "AcceptRejected via Call_err is non-retryable → Exhausted"

let test_decide_and_record_delegates () =
  let outcome = Call_err (mk_http_err ~code:500 ()) in
  let direct = decide ~accept_on_exhaustion:false ~is_last:false outcome in
  let recorded =
    decide_and_record ~runtime_id:"rt-test" ~accept_on_exhaustion:false
      ~is_last:false outcome
  in
  match direct, recorded with
  | Try_next _, Try_next _ -> ()
  | _ -> Alcotest.fail "decide_and_record must match decide for the same outcome"

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
    [ ( "should_try_next"
      , [ Alcotest.test_case "HTTP 408" `Quick test_should_try_http_408
        ; Alcotest.test_case "HTTP 409" `Quick test_should_try_http_409
        ; Alcotest.test_case "HTTP 429" `Quick test_should_try_http_429
        ; Alcotest.test_case "HTTP 500" `Quick test_should_try_http_500
        ; Alcotest.test_case "HTTP 400" `Quick test_should_try_http_400
        ; Alcotest.test_case "HTTP 404" `Quick test_should_try_http_404
        ; Alcotest.test_case "network error" `Quick test_should_try_network
        ; Alcotest.test_case "timeout" `Quick test_should_try_timeout
        ; Alcotest.test_case "provider terminal" `Quick test_should_try_terminal
        ; Alcotest.test_case "accept rejected" `Quick test_should_try_accept_rejected
        ] )
    ; ( "decide"
      , [ Alcotest.test_case "retryable not-last" `Quick
            test_decide_call_err_retryable_not_last
        ; Alcotest.test_case "retryable last" `Quick
            test_decide_call_err_retryable_last
        ; Alcotest.test_case "terminal not-last" `Quick
            test_decide_call_err_terminal_not_last
        ; Alcotest.test_case "accept-rejected via Call_err" `Quick
            test_decide_accept_rejected_not_last
        ; Alcotest.test_case "decide_and_record delegates" `Quick
            test_decide_and_record_delegates
        ] )
    ; ( "to_user_message"
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
