(** Unit tests for [Runtime_attempt_fsm.should_try_next], the retry
    predicate the runtime candidate walk reads. *)

open Runtime_attempt_fsm

let mk_http_err ?(code = 429) ?(body = "") () =
  Llm_provider.Http_client.HttpError
    { code; body = Llm_provider.Http_client.Received body; retry_after_header = None }

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
    ]
