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
  match decide ~accept_on_exhaustion:false ~is_last:false (Call_err (mk_http_err ~code:429 ())) with
  | Try_next _ -> Alcotest.(check bool) "retryable+not-last → Try_next" true true
  | _ -> Alcotest.fail "retryable+not-last should yield Try_next"

let test_decide_call_err_retryable_last () =
  match decide ~accept_on_exhaustion:false ~is_last:true (Call_err (mk_http_err ~code:429 ())) with
  | Exhausted _ -> Alcotest.(check bool) "retryable+last → Exhausted" true true
  | _ -> Alcotest.fail "retryable+last should yield Exhausted"

let test_decide_call_err_not_retryable () =
  match decide ~accept_on_exhaustion:false ~is_last:false (Call_err (mk_provider_terminal ())) with
  | Exhausted _ -> Alcotest.(check bool) "not-retryable → Exhausted" true true
  | _ -> Alcotest.fail "not-retryable should yield Exhausted"

(* --- decide_and_record — source propagation via Call_err --- *)

let test_decide_and_record_try_next_source_none () =
  match decide_and_record ~runtime_id:"test" ~accept_on_exhaustion:false ~is_last:false
           (Call_err (mk_http_err ~code:429 ())) with
  | Try_next { source; _ } ->
    Alcotest.(check (option string)) "default source = None" None source
  | _ -> Alcotest.fail "expected Try_next from retryable Call_err"

(* --- to_user_message --- *)

let test_user_message_http () =
  let msg = to_user_message (Some (mk_http_err ~code:503 ~body:"service unavailable" ())) in
  Alcotest.(check bool) "HTTP 503 in message" true (String.length msg > 0)

let test_user_message_none () =
  Alcotest.(check string) "none → message" "No providers available" (to_user_message None)

(* --- provider_outcome_to_string — Call_err only --- *)

let test_outcome_to_string_call_err () =
  Alcotest.(check string) "Call_err" "call-err" (provider_outcome_to_string (Call_err (mk_http_err ())))

(* --- suite --- *)
let suite =
  [ ("should_try_next", [
      Alcotest.test_case "408 should retry" `Quick test_should_try_http_408;
      Alcotest.test_case "429 should retry" `Quick test_should_try_http_429;
      Alcotest.test_case "500 should retry" `Quick test_should_try_http_500;
      Alcotest.test_case "400 should not retry" `Quick test_should_try_http_400;
      Alcotest.test_case "network error should retry" `Quick test_should_try_network;
      Alcotest.test_case "timeout should retry" `Quick test_should_try_timeout;
      Alcotest.test_case "terminal should not retry" `Quick test_should_try_terminal;
      Alcotest.test_case "accept/reject not retry" `Quick test_should_try_accept_rejected;
    ]);
    ("decide (Call_err paths)", [
      Alcotest.test_case "retryable+not-last → Try_next" `Quick test_decide_call_err_retryable_not_last;
      Alcotest.test_case "retryable+last → Exhausted" `Quick test_decide_call_err_retryable_last;
      Alcotest.test_case "not-retryable → Exhausted" `Quick test_decide_call_err_not_retryable;
    ]);
    ("decide_and_record", [
      Alcotest.test_case "default source = None" `Quick test_decide_and_record_try_next_source_none;
    ]);
    ("to_user_message", [
      Alcotest.test_case "HTTP 503 in message" `Quick test_user_message_http;
      Alcotest.test_case "none → message" `Quick test_user_message_none;
    ]);
    ("provider_outcome_to_string", [
      Alcotest.test_case "Call_err" `Quick test_outcome_to_string_call_err;
    ]);
  ]