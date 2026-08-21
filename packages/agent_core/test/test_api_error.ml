open Alcotest
open Agent_core
module Api_error = Llm_provider.Api_error

let expect_rate_limited err =
  match err with
  | Api_error.RateLimited { message; _ } ->
    check string "rate limited message" "rate limited" message
  | _ -> fail "Expected RateLimited"
;;

let expect_auth_error err =
  match err with
  | Api_error.AuthError { message } -> check string "auth error message" "invalid key" message
  | _ -> fail "Expected AuthError"
;;

let expect_server_error err =
  match err with
  | Api_error.ServerError { status; _ } -> check int "server status" 500 status
  | _ -> fail "Expected ServerError"
;;

let expect_overloaded err =
  match err with
  | Api_error.Overloaded _ -> ()
  | _ -> fail "Expected Overloaded"
;;

let test_classify_error () =
  Api_error.classify_error
    ~retry_after_header:None
    ~status:429
    ~body:{|{"error":{"message":"rate limited"}}|}
  |> expect_rate_limited;
  Api_error.classify_error
    ~retry_after_header:None
    ~status:401
    ~body:{|{"error":{"message":"invalid key"}}|}
  |> expect_auth_error;
  Api_error.classify_error ~retry_after_header:None ~status:500 ~body:"internal error"
  |> expect_server_error;
  Api_error.classify_error ~retry_after_header:None ~status:529 ~body:"overloaded"
  |> expect_overloaded
;;

let test_classify_error_edge_cases () =
  (* 429 with retry_after field *)
  (match
     Api_error.classify_error
       ~retry_after_header:None
       ~status:429
       ~body:{|{"error":{"message":"slow down","retry_after":2.5}}|}
   with
   | Api_error.RateLimited { retry_after = Some ra; _ } ->
     check (float 0.01) "retry_after parsed" 2.5 ra
   | Api_error.RateLimited { retry_after = None; _ } -> fail "expected retry_after to be Some"
   | _ -> fail "expected RateLimited");
  (* 422 -> InvalidRequest *)
  (match
     Api_error.classify_error ~retry_after_header:None ~status:422 ~body:"validation error"
   with
   | Api_error.InvalidRequest { message } ->
     check string "422 message" "validation error" message
   | _ -> fail "expected InvalidRequest for 422");
  (* 502 -> ServerError *)
  (match
     Api_error.classify_error ~retry_after_header:None ~status:502 ~body:"bad gateway"
   with
   | Api_error.ServerError { status; _ } -> check int "502 status" 502 status
   | _ -> fail "expected ServerError for 502");
  (* malformed JSON body -> falls back to raw body *)
  (match
     Api_error.classify_error ~retry_after_header:None ~status:500 ~body:"not json at all"
   with
   | Api_error.ServerError { message; _ } ->
     check string "raw body fallback" "not json at all" message
   | _ -> fail "expected ServerError with raw body");
  (* 404 -> NotFound *)
  match Api_error.classify_error ~retry_after_header:None ~status:404 ~body:"not found" with
  | Api_error.NotFound { message } -> check string "404 not found" "not found" message
  | _ -> fail "expected NotFound for 404"
;;

let test_classify_error_402_payment_required () =
  let body = {|{"error":{"message":"Insufficient Balance"}}|} in
  let err = Api_error.classify_error ~retry_after_header:None ~status:402 ~body in
  (match err with
   | Api_error.PaymentRequired { message } ->
     check string "402 message" "Insufficient Balance" message
   | _ -> fail "expected PaymentRequired for 402");
  check
    string
    "402 error_message rendering"
    "Payment required: Insufficient Balance"
    (Api_error.error_message err)
;;

let test_classify_error_403_authorization_denied () =
  let body =
    {|{"error":{"message":"You've reached your usage limit for this billing cycle"}}|}
  in
  let err = Api_error.classify_error ~retry_after_header:None ~status:403 ~body in
  (match err with
   | Api_error.AuthorizationError { message } ->
     check
       string
       "403 provider detail"
       "You've reached your usage limit for this billing cycle"
       message
   | _ -> fail "expected AuthorizationError for 403")
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
    match Api_error.classify_error ~retry_after_header:None ~status:429 ~body with
    | Api_error.RateLimited { retry_after; _ } -> retry_after
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

(* 413 states its cause in the status line. Before this it fell through the final
   catch-all of classify_error and arrived as Unknown_invalid_request, which a consumer
   must read as a defect in what it built rather than a size it can reduce — the
   distinction that decides whether shrinking the input is worth trying. *)
let test_payload_too_large_is_classified_from_the_status () =
  (match
     Api_error.classify_error
       ~retry_after_header:None
       ~status:413
       ~body:{|{"error":{"message":"request body too large"}}|}
   with
   | Api_error.InvalidRequest
       { reason = Api_error.Request_body_refused_by_provider { status = 413 }; message } ->
     check string "the provider message survives" "request body too large" message
   | Api_error.InvalidRequest { reason = Api_error.Unknown_invalid_request; _ } ->
     fail "413 was classified as an unknown invalid request"
   | _ -> fail "413 was not classified as an invalid request at all");
  (* The limit is absent on purpose: a 413 response carries a status, not a bound, and
     Request_body_too_large means a measured pair. *)
  (match Api_error.classify_error ~retry_after_header:None ~status:413 ~body:"" with
   | Api_error.InvalidRequest { reason = Api_error.Request_body_too_large _; _ } ->
     fail "a provider refusal was given fabricated measurements"
   | _ -> ());
  (* Neighbouring statuses keep their own classification. *)
  match
    ( Api_error.classify_error ~retry_after_header:None ~status:400 ~body:""
    , Api_error.classify_error ~retry_after_header:None ~status:422 ~body:"" )
  with
  | ( Api_error.InvalidRequest { reason = Api_error.Unknown_invalid_request; _ }
    , Api_error.InvalidRequest { reason = Api_error.Unknown_invalid_request; _ } ) -> ()
  | _ -> fail "400/422 classification moved with the 413 arm"
;;

let test_invalid_request_reason_boundary () =
  let expect_unknown body =
    match Api_error.classify_error ~retry_after_header:None ~status:400 ~body with
    | Api_error.InvalidRequest { reason = Unknown_invalid_request; _ } -> ()
    | _ -> fail "expected Unknown_invalid_request"
  in
  List.iter
    expect_unknown
    [ {|{"error":{"message":"Unexpected character in user.name string exceeds length"}}|}
    ; {|{"error":{"message":"parse error in query parameters"}}|}
    ; {|{"error":{"message":"unexpected token in tool schema"}}|}
    ; "JSON parse error: unexpected token"
    ];
  match
    Api_error.InvalidRequest
      { message = "JSON parse error: unexpected token"; reason = Api_error.Json_parse_error }
  with
  | Api_error.InvalidRequest { reason = Api_error.Json_parse_error; _ } -> ()
  | _ -> fail "expected typed parser-boundary reason"
;;

let test_error_message_all_variants () =
  let cases =
    [ Api_error.RateLimited { retry_after = None; message = "slow" }, "Rate limited: slow"
    ; Api_error.Overloaded { message = "busy" }, "Overloaded: busy"
    ; Api_error.ServerError { status = 503; message = "down" }, "Server error 503: down"
    ; Api_error.AuthError { message = "bad key" }, "Auth error: bad key"
    ; Api_error.AuthorizationError { message = "forbidden" }, "Authorization error: forbidden"
    ; ( Api_error.PaymentRequired { message = "Insufficient Balance" }
      , "Payment required: Insufficient Balance" )
    ; ( Api_error.InvalidRequest { message = "wrong"; reason = Unknown_invalid_request }
      , "Invalid request (unknown): wrong" )
    ; Api_error.NotFound { message = "no model" }, "Not found: no model"
    ; Api_error.NetworkError { message = "dns"; kind = Unknown }, "Network error: dns"
    ; ( Api_error.NetworkError
          { message = "failed to resolve hostname: api.z.ai"; kind = Dns_failure }
      , "Network error (dns_failure): failed to resolve hostname: api.z.ai" )
    ; ( Api_error.NetworkError { message = "reset"; kind = Connection_refused }
      , "Network error (connection_refused): reset" )
    ; Api_error.Timeout { message = "10s"; phase = None }, "Timeout: 10s"
    ]
  in
  List.iter
    (fun (err, expected) ->
       check string "error_message" expected (Api_error.error_message err))
    cases
;;

let () =
  run
    "Api_error"
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
        ; test_case
            "invalid request reason boundary"
            `Quick
            test_invalid_request_reason_boundary
        ; test_case "error_message all variants" `Quick test_error_message_all_variants
        ] )
    ]
;;
