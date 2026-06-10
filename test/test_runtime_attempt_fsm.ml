(** Unit tests for Runtime_attempt_fsm — pure decision logic.
    Tests only Call_err and should_try_next paths to avoid constructing
    the opaque Agent_sdk.Types.api_response value. *)

open Masc.Runtime_attempt_fsm

let mk_http_err ?(code=429) ?(body="") () =
  Llm_provider.Http_client.HttpError { code; body }

let mk_network_err ?(message="net err") () =
  Llm_provider.Http_client.NetworkError { message; kind = Llm_provider.Http_client.Unknown }

let mk_timeout_err ?(message="timeout") ?(phase="test") () =
  Llm_provider.Http_client.TimeoutError { message; phase }

let mk_provider_terminal ?(message="terminal") ?(kind="provider") () =
  Llm_provider.Http_client.ProviderTerminal { kind; message }

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
  match decide_and_record ~runtime_id:"test" ~source:(Some "backpressure") ~accept_on_exhaustion:false ~is_last:false
           (Call_err (mk_http_err ~code:429 ())) with
  | Try_next { source; _ } ->
    Alcotest.(check (option string)) "source=backpressure carried through" (Some "backpressure") source
  | _ -> Alcotest.fail "expected Try_next with source propagation"

(* --- decide_and_record — log_warn spy --- *)

let test_decide_and_record_log_warn () =
  let buf = Buffer.create 64 in
  let spy msg = Buffer.add_string buf msg in
  let _ = decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:false
              ~log_warn:spy (Call_err (mk_http_err ~code:429 ())) in
  let logged = Buffer.contents buf in
  Alcotest.(check bool) "log_warn spy was called" true (String.length logged > 0)

let test_decide_and_record_log_warn_not_called () =
  let buf = Buffer.create 64 in
  let spy msg = Buffer.add_string buf msg in
  let _ = decide_and_record ~runtime_id:"test" ~source:None ~accept_on_exhaustion:false ~is_last:true
              ~log_warn:spy (Call_err (mk_provider_terminal ())) in
  let logged = Buffer.contents buf in
  Alcotest.(check bool) "log_warn not called on Exhausted" false (String.length logged > 0)

(* --- Test registration --- *)

let () =
  Alcotest.run "Runtime_attempt_fsm" [
    "should_try_next", [
      test_case "408" `Quick test_should_try_http_408;
      test_case "429" `Quick test_should_try_http_429;
      test_case "500" `Quick test_should_try_http_500;
      test_case "400" `Quick test_should_try_http_400;
      test_case "network error" `Quick test_should_try_network;
      test_case "timeout" `Quick test_should_try_timeout;
      test_case "terminal" `Quick test_should_try_terminal;
    ];
    "decide Call_err", [
      test_case "retryable not last" `Quick test_decide_call_err_retryable_not_last;
      test_case "retryable last" `Quick test_decide_call_err_retryable_last;
      test_case "not retryable" `Quick test_decide_call_err_not_retryable;
    ];
    "decide_and_record", [
      test_case "source None" `Quick test_decide_and_record_try_next_source_none;
      test_case "exhausted retryable last" `Quick test_decide_and_record_exhausted_retryable_last;
      test_case "exhausted terminal" `Quick test_decide_and_record_exhausted_terminal;
      test_case "source Some" `Quick test_decide_and_record_try_next_source_some;
    ];
    "log_warn spy", [
      test_case "called on retryable" `Quick test_decide_and_record_log_warn;
      test_case "not called on terminal" `Quick test_decide_and_record_log_warn_not_called;
    ];
  ]

(* Note:
   - Removed mk_accept_rejected / test_should_try_accept_rejected:
     Accept_rejected is a provider_outcome variant, not an http_error.
     should_try_next only accepts http_error.
   - mk_timeout_err: added ~phase param — real type is { message; phase }
   - mk_provider_terminal: added ~kind param — real type is { kind; message }
*)