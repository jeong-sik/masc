(** Unit tests for Runtime_attempt_fsm — pure decision logic.
    Tests only Call_err and should_try_next paths to avoid constructing
    the opaque Agent_sdk.Types.api_response value. *)

open Masc.Runtime_attempt_fsm

let mk_http_err ?(code=429) ?(body="") () =
  Llm_provider.Http_client.HttpError { code; body }

let mk_network_err ?(message="net err") () =
  Llm_provider.Http_client.NetworkError { message; kind = Llm_provider.Http_client.Unknown }

let mk_timeout_err ?(message="timeout") () =
  Llm_provider.Http_client.TimeoutError { message }

let mk_provider_terminal ?(message="terminal") () =
  Llm_provider.Http_client.ProviderTerminal { message }

let mk_accept_rejected ?(reason="quality") () =
  Llm_provider.Http_client.AcceptRejected { reason }

(* --- should_try_next --- *)

let test_should_try_http_408 () =
  Alcotest.(check bool) "408 should retry" true (should_try_next (mk_http_err ~code:408 ~body:"timeout" ()))

let test_should_try_http_429 () =
  Alcotest.(check bool) "429 should retry" true (should_try_next (mk_http_err ~code:429 ()))

let test_should_try_http_500 () =
  Alcotest.(check bool) "500 should retry" true (should_try_next (mk_http_err ~code:500 ()))

let test_should_try_http_400 () =
  Alcotest.(check bool) "400 should not retry" false (should_try_next (mk_http_err ~code:400 ()))

let test_should_try_network () =
  Alcotest.(check bool) "network error should retry" true (should_try_next (mk_network_err ()))

let test_should_try_timeout () =
  Alcotest.(check bool) "timeout should retry" true (should_try_next (mk_timeout_err ()))

let test_should_try_terminal () =
  Alcotest.(check bool) "terminal should not retry" false (should_try_next (mk_provider_terminal ()))

let test_should_try_accept_rejected () =
  Alcotest.(check bool) "accept/reject should not retry" false (should_try_next (mk_accept_rejected ()))

(* --- decide — Call_err paths only --- *)

let test_decide_call_err_retryable_not_last () =
  match decide ~accept_on_exhaustion:false ~is_last:false ~source:None (Call_err (mk_http_err ~code:429 ())) with
  | Try_next _ -> Alcotest.(check bool) "retryable+not-last → Try_next" true true
  | _ -> Alcotest.fail "retryable+not-last should yield Try_next"

let test_decide_call_err_retryable_last () =
  match decide ~accept_on_exhaustion:false ~is_last:true ~source:None (Call_err (mk_http_err ~code:429 ())) with
  | Exhausted _ -> Alcotest.(check bool) "retryable+last → Exhausted" true true
  | _ -> Alcotest.fail "retryable+last should yield Exhausted"

let test_decide_call_err_not_retryable () =
  match decide ~accept_on_exhaustion:false ~is_last:false ~source:None (Call_err (mk_provider_terminal ())) with
  | Exhausted _ -> Alcotest.(check bool) "not-retryable → Exhausted" true true
  | _ -> Alcotest.fail "not-retryable should yield Exhausted"

(* --- decide_and_record — source propagation via Call_err --- *)

let test_decide_and_record_try_next_source_none () =
  match decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:false
           (Call_err (mk_http_err ~code:429 ())) with
  | Try_next { source; _ } ->
    Alcotest.(check (option string)) "default source = None" None source
  | _ -> Alcotest.fail "expected Try_next from retryable Call_err"

let test_decide_and_record_exhausted_retryable_last () =
  match decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:true
           (Call_err (mk_http_err ~code:429 ())) with
  | Exhausted _ -> Alcotest.(check bool) "retryable+last → Exhausted via decide_and_record" true true
  | _ -> Alcotest.fail "retryable+last should yield Exhausted via decide_and_record"

let test_decide_and_record_exhausted_terminal () =
  match decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:false
           (Call_err (mk_provider_terminal ())) with
  | Exhausted _ -> Alcotest.(check bool) "terminal → Exhausted via decide_and_record" true true
  | _ -> Alcotest.fail "terminal should yield Exhausted via decide_and_record"

let test_decide_and_record_try_next_source_some () =
  match decide_and_record ~runtime_id:"test" ~source:(Some "provider-x") ~accept_on_exhaustion:false ~is_last:false
           (Call_err (mk_http_err ~code:429 ())) with
  | Try_next { source; _ } ->
    Alcotest.(check (option string)) "source = Some provider-x" (Some "provider-x") source
  | _ -> Alcotest.fail "expected Try_next from retryable Call_err with source=Some"

(* --- decide_and_record — log_warn spy tests --- *)

let test_decide_and_record_log_warn_try_next () =
  let called = ref false in
  let spy _ = called := true in
  let _ = decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:false
              ~log_warn:spy (Call_err (mk_http_err ~code:429 ())) in
  Alcotest.(check bool) "log_warn called for Try_next" true !called

let test_decide_and_record_log_warn_exhausted () =
  let called = ref false in
  let spy _ = called := true in
  let _ = decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:true
              ~log_warn:spy (Call_err (mk_http_err ~code:429 ())) in
  Alcotest.(check bool) "log_warn called for Exhausted" true !called

(* --- to_user_message --- *)

let test_user_message_http () =
  let msg = to_user_message (Some (mk_http_err ~code:503 ())) in
  Alcotest.(check bool) "includes 503" true (String.contains msg '5')

let test_user_message_none () =
  let msg = to_user_message None in
  Alcotest.(check bool) "none message non-empty" true (String.length msg > 0)

(* --- provider_outcome_to_string --- *)

let test_outcome_to_string_call_err () =
  let s = provider_outcome_to_string (Call_err (mk_http_err ~code:429 ())) in
  Alcotest.(check bool) "call_err serializes" true (String.length s > 0)

(* --- suite --- *)

let suite =
  [
    ("should_try_next", [
      Alcotest.test_case "HTTP 408" `Quick test_should_try_http_408;
      Alcotest.test_case "HTTP 429" `Quick test_should_try_http_429;
      Alcotest.test_case "HTTP 500" `Quick test_should_try_http_500;
      Alcotest.test_case "HTTP 400" `Quick test_should_try_http_400;
      Alcotest.test_case "network error" `Quick test_should_try_network;
      Alcotest.test_case "timeout" `Quick test_should_try_timeout;
      Alcotest.test_case "terminal" `Quick test_should_try_terminal;
      Alcotest.test_case "accept/rejected" `Quick test_should_try_accept_rejected;
    ]);
    ("decide - Call_err", [
      Alcotest.test_case "retryable not-last" `Quick test_decide_call_err_retryable_not_last;
      Alcotest.test_case "retryable last" `Quick test_decide_call_err_retryable_last;
      Alcotest.test_case "not-retryable" `Quick test_decide_call_err_not_retryable;
    ]);
    ("decide_and_record", [
      Alcotest.test_case "default source = None" `Quick test_decide_and_record_try_next_source_none;
      Alcotest.test_case "exhausted retryable+last" `Quick test_decide_and_record_exhausted_retryable_last;
      Alcotest.test_case "exhausted terminal" `Quick test_decide_and_record_exhausted_terminal;
      Alcotest.test_case "source = Some provider-x" `Quick test_decide_and_record_try_next_source_some;
      Alcotest.test_case "log_warn called for Try_next" `Quick test_decide_and_record_log_warn_try_next;
      Alcotest.test_case "log_warn called for Exhausted" `Quick test_decide_and_record_log_warn_exhausted;
    ]);
    ("to_user_message", [
      Alcotest.test_case "HTTP 503 in message" `Quick test_user_message_http;
      Alcotest.test_case "none → message" `Quick test_user_message_none;
    ]);
    ("provider_outcome_to_string", [
      Alcotest.test_case "Call_err" `Quick test_outcome_to_string_call_err;
    ]);
  ]