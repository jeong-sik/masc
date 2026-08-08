open Alcotest
open Agent_sdk
module Retry = Llm_provider.Retry

let expect_rate_limited err =
  match err with
  | Retry.RateLimited { message; _ } ->
    check string "rate limited message" "rate limited" message
  | _ -> fail "Expected RateLimited"
;;

let expect_auth_error err =
  match err with
  | Retry.AuthError { message } -> check string "auth error message" "invalid key" message
  | _ -> fail "Expected AuthError"
;;

let expect_server_error err =
  match err with
  | Retry.ServerError { status; _ } -> check int "server status" 500 status
  | _ -> fail "Expected ServerError"
;;

let expect_overloaded err =
  match err with
  | Retry.Overloaded _ -> ()
  | _ -> fail "Expected Overloaded"
;;

let test_classify_error () =
  Retry.classify_error
    ~retry_after_header:None
    ~status:429
    ~body:{|{"error":{"message":"rate limited"}}|}
  |> expect_rate_limited;
  Retry.classify_error
    ~retry_after_header:None
    ~status:401
    ~body:{|{"error":{"message":"invalid key"}}|}
  |> expect_auth_error;
  Retry.classify_error ~retry_after_header:None ~status:500 ~body:"internal error"
  |> expect_server_error;
  Retry.classify_error ~retry_after_header:None ~status:529 ~body:"overloaded"
  |> expect_overloaded
;;

let test_classify_error_edge_cases () =
  (* 429 with retry_after field *)
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:429
       ~body:{|{"error":{"message":"slow down","retry_after":2.5}}|}
   with
   | Retry.RateLimited { retry_after = Some ra; _ } ->
     check (float 0.01) "retry_after parsed" 2.5 ra
   | Retry.RateLimited { retry_after = None; _ } -> fail "expected retry_after to be Some"
   | _ -> fail "expected RateLimited");
  (* 422 -> InvalidRequest *)
  (match
     Retry.classify_error ~retry_after_header:None ~status:422 ~body:"validation error"
   with
   | Retry.InvalidRequest { message } ->
     check string "422 message" "validation error" message
   | _ -> fail "expected InvalidRequest for 422");
  (* 502 -> ServerError *)
  (match
     Retry.classify_error ~retry_after_header:None ~status:502 ~body:"bad gateway"
   with
   | Retry.ServerError { status; _ } -> check int "502 status" 502 status
   | _ -> fail "expected ServerError for 502");
  (* malformed JSON body -> falls back to raw body *)
  (match
     Retry.classify_error ~retry_after_header:None ~status:500 ~body:"not json at all"
   with
   | Retry.ServerError { message; _ } ->
     check string "raw body fallback" "not json at all" message
   | _ -> fail "expected ServerError with raw body");
  (* 404 -> NotFound *)
  match Retry.classify_error ~retry_after_header:None ~status:404 ~body:"not found" with
  | Retry.NotFound { message } -> check string "404 not found" "not found" message
  | _ -> fail "expected NotFound for 404"
;;

let test_classify_error_402_payment_required () =
  let body = {|{"error":{"message":"Insufficient Balance"}}|} in
  let err = Retry.classify_error ~retry_after_header:None ~status:402 ~body in
  (match err with
   | Retry.PaymentRequired { message } ->
     check string "402 message" "Insufficient Balance" message
   | _ -> fail "expected PaymentRequired for 402");
  check bool "402 is not retryable" false (Retry.is_retryable err);
  check
    string
    "402 error_message rendering"
    "Payment required: Insufficient Balance"
    (Retry.error_message err)
;;

let test_classify_error_403_authorization_denied () =
  let body =
    {|{"error":{"message":"You've reached your usage limit for this billing cycle"}}|}
  in
  let err = Retry.classify_error ~retry_after_header:None ~status:403 ~body in
  (match err with
   | Retry.AuthorizationError { message } ->
     check
       string
       "403 provider detail"
       "You've reached your usage limit for this billing cycle"
       message
   | _ -> fail "expected AuthorizationError for 403");
  check bool "403 is not retryable" false (Retry.is_retryable err)
;;

(* #2644: a hostile or malformed 429 body may carry a non-finite or negative
   [error.retry_after]. Yojson parses [NaN]/[Infinity]/[-Infinity] and
   overflowing exponents ([1e400]) into non-finite floats, and [-5.0] into a
   negative one. The parse boundary must reject all of these so no bad float
   reaches a sleep/backoff computation; the value then falls through to the
   header (here [None]). A finite non-negative value is preserved unchanged.
   These cases fail if the [usable_retry_after] guard is reverted. *)
let test_classify_error_429_retry_after_finite_guard () =
  let retry_after_of body =
    match Retry.classify_error ~retry_after_header:None ~status:429 ~body with
    | Retry.RateLimited { retry_after; _ } -> retry_after
    | _ -> fail "expected RateLimited for 429"
  in
  let expect_none label body =
    match retry_after_of body with
    | None -> ()
    | Some bad -> failf "%s: expected retry_after None, got Some %f" label bad
  in
  expect_none "NaN body retry_after" {|{"error":{"retry_after":NaN}}|};
  expect_none "Infinity body retry_after" {|{"error":{"retry_after":Infinity}}|};
  expect_none "-Infinity body retry_after" {|{"error":{"retry_after":-Infinity}}|};
  expect_none "overflow-exponent body retry_after" {|{"error":{"retry_after":1e400}}|};
  expect_none "negative body retry_after" {|{"error":{"retry_after":-5.0}}|};
  (* Valid finite non-negative value is unchanged (no regression). *)
  match retry_after_of {|{"error":{"retry_after":3.0}}|} with
  | Some ra -> check (float 0.0) "valid retry_after preserved" 3.0 ra
  | None -> fail "expected retry_after Some 3.0 for a valid body"
;;

let test_is_retryable () =
  check
    bool
    "rate limited retryable"
    true
    (Retry.is_retryable (Retry.RateLimited { retry_after = None; message = "" }));
  check
    bool
    "overloaded retryable"
    true
    (Retry.is_retryable (Retry.Overloaded { message = "" }));
  check
    bool
    "server retryable"
    true
    (Retry.is_retryable (Retry.ServerError { status = 500; message = "" }));
  check
    bool
    "network retryable"
    true
    (Retry.is_retryable (Retry.NetworkError { message = ""; kind = Unknown }));
  check
    bool
    "timeout retryable"
    true
    (Retry.is_retryable (Retry.Timeout { message = ""; phase = None }));
  check
    bool
    "auth not retryable"
    false
    (Retry.is_retryable (Retry.AuthError { message = "" }));
  check
    bool
    "invalid request not retryable"
    false
    (Retry.is_retryable
       (Retry.InvalidRequest { message = ""; reason = Unknown_invalid_request }));
  check
    bool
    "not found not retryable"
    false
    (Retry.is_retryable (Retry.NotFound { message = "" }));
  check
    bool
    "payment required not retryable"
    false
    (Retry.is_retryable (Retry.PaymentRequired { message = "" }))
;;

(* 413 states its cause in the status line. Before this it fell through the final
   catch-all of classify_error and arrived as Unknown_invalid_request, which a consumer
   must read as a defect in what it built rather than a size it can reduce — the
   distinction that decides whether shrinking the input is worth trying. *)
let test_payload_too_large_is_classified_from_the_status () =
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:413
       ~body:{|{"error":{"message":"request body too large"}}|}
   with
   | Retry.InvalidRequest
       { reason = Retry.Request_body_refused_by_provider { status = 413 }; message } ->
     check string "the provider message survives" "request body too large" message
   | Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } ->
     fail "413 was classified as an unknown invalid request"
   | _ -> fail "413 was not classified as an invalid request at all");
  (* The limit is absent on purpose: a 413 response carries a status, not a bound, and
     Request_body_too_large means a measured pair. *)
  (match Retry.classify_error ~retry_after_header:None ~status:413 ~body:"" with
   | Retry.InvalidRequest { reason = Retry.Request_body_too_large _; _ } ->
     fail "a provider refusal was given fabricated measurements"
   | _ -> ());
  (* Neighbouring statuses keep their own classification. *)
  match
    ( Retry.classify_error ~retry_after_header:None ~status:400 ~body:""
    , Retry.classify_error ~retry_after_header:None ~status:422 ~body:"" )
  with
  | ( Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ }
    , Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } ) -> ()
  | _ -> fail "400/422 classification moved with the 413 arm"
;;

let test_invalid_request_reason_boundary () =
  let expect_unknown body =
    match Retry.classify_error ~retry_after_header:None ~status:400 ~body with
    | Retry.InvalidRequest { reason = Unknown_invalid_request; _ } as err ->
      check bool "generic invalid request is not retryable" false (Retry.is_retryable err)
    | _ -> fail "expected Unknown_invalid_request"
  in
  List.iter
    expect_unknown
    [ {|{"error":{"message":"Unexpected character in user.name string exceeds length"}}|}
    ; {|{"error":{"message":"parse error in query parameters"}}|}
    ; {|{"error":{"message":"unexpected token in tool schema"}}|}
    ; "JSON parse error: unexpected token"
    ];
  check
    bool
    "typed parser-boundary invalid request is retryable"
    true
    (Retry.is_retryable
       (Retry.InvalidRequest
          { message = "JSON parse error: unexpected token"
          ; reason = Retry.Json_parse_error
          }))
;;

let test_error_message_all_variants () =
  let cases =
    [ Retry.RateLimited { retry_after = None; message = "slow" }, "Rate limited: slow"
    ; Retry.Overloaded { message = "busy" }, "Overloaded: busy"
    ; Retry.ServerError { status = 503; message = "down" }, "Server error 503: down"
    ; Retry.AuthError { message = "bad key" }, "Auth error: bad key"
    ; Retry.AuthorizationError { message = "forbidden" }, "Authorization error: forbidden"
    ; ( Retry.PaymentRequired { message = "Insufficient Balance" }
      , "Payment required: Insufficient Balance" )
    ; ( Retry.InvalidRequest { message = "wrong"; reason = Unknown_invalid_request }
      , "Invalid request (unknown): wrong" )
    ; Retry.NotFound { message = "no model" }, "Not found: no model"
    ; Retry.NetworkError { message = "dns"; kind = Unknown }, "Network error: dns"
    ; ( Retry.NetworkError
          { message = "failed to resolve hostname: api.z.ai"; kind = Dns_failure }
      , "Network error (dns_failure): failed to resolve hostname: api.z.ai" )
    ; ( Retry.NetworkError { message = "reset"; kind = Connection_refused }
      , "Network error (connection_refused): reset" )
    ; Retry.Timeout { message = "10s"; phase = None }, "Timeout: 10s"
    ]
  in
  List.iter
    (fun (err, expected) ->
       check string "error_message" expected (Retry.error_message err))
    cases
;;

let () =
  run
    "Retry"
    [ ( "classify"
      , [ test_case "http status mapping" `Quick test_classify_error
        ; test_case "edge cases" `Quick test_classify_error_edge_cases
        ; test_case "402 payment required" `Quick test_classify_error_402_payment_required
        ; test_case
            "403 authorization denied"
            `Quick
            test_classify_error_403_authorization_denied
        ; test_case
            "429 retry_after finite guard"
            `Quick
            test_classify_error_429_retry_after_finite_guard
        ] )
    ; ( "typed_projection"
      , [ test_case
            "413 is classified from the status"
            `Quick
            test_payload_too_large_is_classified_from_the_status
        ; test_case "retryable predicates" `Quick test_is_retryable
        ; test_case
            "invalid request reason boundary"
            `Quick
            test_invalid_request_reason_boundary
        ; test_case "error_message all variants" `Quick test_error_message_all_variants
        ] )
    ]
;;
