open Alcotest
open Agent_core
module Retry = Llm_provider.Retry
module Http_client = Llm_provider.Http_client

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

let test_server_refusal_status_boundaries () =
  let body = {|{"error":{"message":"provider unavailable"}}|} in
  List.iter
    (fun (status, expected) ->
       let error = Retry.classify_error ~retry_after_header:None ~status ~body in
       (match expected, error with
        | `Server_error, Retry.ServerError { status = actual; message } ->
          check int "original status survives" status actual;
          check string "provider message survives" "provider unavailable" message
        | `Overloaded, Retry.Overloaded { message } ->
          check string "provider message survives" "provider unavailable" message
        | `Unclassified,
          Retry.InvalidRequest { reason = Retry.Unclassified_status { status = carried }; message } ->
          check int "the unclassified status survives" status carried;
          check string "provider message survives" "provider unavailable" message
        | _ -> failf "HTTP %d classified as %s" status (Retry.error_message error));
       check bool "only server refusals are retryable"
         (expected <> `Unclassified) (Retry.is_retryable error))
    [ 499, `Unclassified
    ; 500, `Server_error
    ; 503, `Server_error
    ; 520, `Server_error
    ; 529, `Overloaded
    ; 599, `Server_error
    ; 600, `Unclassified
    ]
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

(* JSON has one number grammar, so providers may encode whole-second retry
   hints as integers. Both number representations are accepted; strings remain
   outside the typed boundary even when their contents look numeric. *)
let test_classify_error_429_retry_after_json_numbers () =
  let retry_after_of body =
    match Retry.classify_error ~retry_after_header:None ~status:429 ~body with
    | Retry.RateLimited { retry_after; _ } -> retry_after
    | _ -> fail "expected RateLimited for 429"
  in
  List.iter
    (fun (label, body, expected) ->
       match retry_after_of body with
       | Some actual -> check (float 0.0) label expected actual
       | None -> failf "%s: expected retry_after Some %f" label expected)
    [ "integer retry_after", {|{"error":{"retry_after":7}}|}, 7.0
    ; "float retry_after", {|{"error":{"retry_after":7.5}}|}, 7.5
    ; "zero retry_after", {|{"error":{"retry_after":0}}|}, 0.0
    ];
  match retry_after_of {|{"error":{"retry_after":"7"}}|} with
  | None -> ()
  | Some bad -> failf "string retry_after: expected None, got Some %f" bad
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
    "a reset connection is retryable"
    true
    (Retry.is_retryable (Retry.NetworkError { message = ""; kind = Connection_reset }));
  (* RFC #52028 §2.3: a connection that did not open reads the same kind rule. *)
  check
    bool
    "a refused connection that did not open is retryable"
    true
    (Retry.is_retryable (Retry.Connect_failed { message = ""; kind = Connection_refused }));
  check
    bool
    "a TLS handshake that did not open is not retryable"
    false
    (Retry.is_retryable (Retry.Connect_failed { message = ""; kind = Tls_error }));
  check
    bool
    "no route to the network or host is retryable"
    true
    (Retry.is_retryable (Retry.NetworkError { message = ""; kind = Unreachable }));
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

(* Only 400 and 422 are refusals of the request with no named cause. A status
   no arm names keeps its own reason and the status, and still ends the
   attempt as the unknown refusal did. *)
let test_unclassified_status_keeps_its_own_reason () =
  List.iter
    (fun status ->
       match Retry.classify_error ~retry_after_header:None ~status ~body:"" with
       | Retry.InvalidRequest { reason = Retry.Unclassified_status { status = carried }; _ }
         as err ->
         check int "the status is carried" status carried;
         check bool "an unclassified status is not retryable" false (Retry.is_retryable err)
       | other ->
         fail
           (Printf.sprintf "HTTP %d: expected Unclassified_status, got %s" status
              (Retry.error_message other)))
    [ 301; 304; 405; 408; 409; 418 ];
  List.iter
    (fun status ->
       match Retry.classify_error ~retry_after_header:None ~status ~body:"" with
       | Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } -> ()
       | other ->
         fail
           (Printf.sprintf "HTTP %d: expected Unknown_invalid_request, got %s" status
              (Retry.error_message other)))
    [ 400; 422 ]
;;

(* A refusal whose body the caller's own window closed on is not a refusal
   whose body arrived empty. The provider named a status and nothing else
   that was read, so the classification says the cause is unread and the
   attempt may be tried again; a body that did arrive and named nothing this
   classifier knows still ends the attempt. *)
let test_a_refusal_body_that_never_arrived_is_not_an_empty_body () =
  let statuses = [ 400; 413; 422; 429; 500; 529 ] in
  List.iter
    (fun status ->
       match
         Retry.classify_refusal
           ~retry_after_header:None
           ~status
           ~body:Llm_provider.Http_client.Not_received_in_window
       with
       | Retry.InvalidRequest { reason = Retry.Refusal_body_not_received; _ } as err ->
         check
           bool
           "a refusal nobody read is retryable"
           true
           (Retry.is_retryable err)
       | other ->
         failf
           "HTTP %d with an unread body classified as %s"
           status
           (Retry.error_message other))
    statuses;
  (* The same statuses with a body that arrived keep their classification. *)
  (match
     Retry.classify_refusal
       ~retry_after_header:None
       ~status:400
       ~body:(Llm_provider.Http_client.Received "")
   with
   | Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } as err ->
     check bool "a body that arrived empty still ends the attempt" false (Retry.is_retryable err)
   | other -> failf "an empty body that arrived classified as %s" (Retry.error_message other));
  match
    Retry.classify_refusal
      ~retry_after_header:None
      ~status:429
      ~body:(Llm_provider.Http_client.Received {|{"error":{"message":"slow down"}}|})
  with
  | Retry.RateLimited { message; _ } ->
    check string "the provider's message survives" "slow down" message
  | other -> failf "a 429 that arrived classified as %s" (Retry.error_message other)
;;

let test_error_message_all_variants () =
  let cases =
    [ ( Retry.RateLimited { retry_after = None; message = "slow" }
      , "Rate limited: slow (retry_after: none)" )
    ; ( Retry.RateLimited { retry_after = Some 123.5; message = "slow" }
      , "Rate limited: slow (retry_after: 123.500s)" )
    ; Retry.Overloaded { message = "busy" }, "Overloaded: busy"
    ; Retry.ServerError { status = 503; message = "down" }, "Server error 503: down"
    ; Retry.AuthError { message = "bad key" }, "Auth error: bad key"
    ; Retry.AuthorizationError { message = "forbidden" }, "Authorization error: forbidden"
    ; Retry.PaymentRequired { message = "Insufficient Balance" }, "Payment required: Insufficient Balance"
    ; ( Retry.InvalidRequest { message = "wrong"; reason = Unknown_invalid_request }
      , "Invalid request (unknown): wrong" )
    ; Retry.NotFound { message = "no model" }, "Not found: no model"
    ; Retry.NetworkError { message = "dns"; kind = Unknown }, "Network error: dns"
    ; ( Retry.NetworkError
          { message = "failed to resolve hostname: api.z.ai"; kind = Dns_failure }
      , "Network error (dns_failure): failed to resolve hostname: api.z.ai" )
    ; ( Retry.NetworkError { message = "refused"; kind = Connection_refused }
      , "Network error (connection_refused): refused" )
    ; ( Retry.NetworkError { message = "reset"; kind = Connection_reset }
      , "Network error (connection_reset): reset" )
    ; ( Retry.NetworkError { message = "no route"; kind = Unreachable }
      , "Network error (unreachable): no route" )
    ; Retry.Timeout { message = "10s"; phase = None }, "Timeout: 10s"
      (* A timeout that does not say which phase stalled reads the same as
         every other timeout. The phase was in the record and absent from
         the rendering, so the only way to see it in a log was to convert
         the error into a provider error it was not. *)
    ; ( Retry.Timeout
          { message = "no token for 120s"
          ; phase = Some (Http_client.Stream_idle Http_client.Streaming_answer)
          }
      , "Timeout phase=stream_idle:streaming_answer: no token for 120s" )
    ; ( Retry.Timeout { message = "prefill"; phase = Some Http_client.First_token }
      , "Timeout phase=first_token: prefill" )
    ]
  in
  List.iter
    (fun (err, expected) ->
       check string "error_message" expected (Retry.error_message err))
    cases
;;

let test_structured_refusal_classification () =
  (* Structured HTTP 400/422 ContextOverflow across OpenAI, llama.cpp, GLM,
     and OpenRouter nested error.metadata.raw — zero prose matching. *)
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"code":"context_length_exceeded","message":"prompt too long"}}|}
   with
   | Retry.ContextOverflow _ -> ()
   | other -> failf "expected ContextOverflow for openai code, got %s" (Retry.error_message other));
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"type":"exceed_context_size_error","n_ctx":32768,"message":"overflow"}}|}
   with
   | Retry.ContextOverflow { limit = Some 32768; _ } -> ()
   | other -> failf "expected ContextOverflow(32768) for llama.cpp, got %s" (Retry.error_message other));
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"code":400,"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too big\"}}"}}}|}
   with
   | Retry.ContextOverflow _ -> ()
   | other -> failf "expected ContextOverflow for openrouter nested raw, got %s" (Retry.error_message other));
  (* Plain 400 prose mentioning context length without a structured code must
     NOT match ContextOverflow (zero prose heuristics). *)
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"message":"your context length is too long"}}|}
   with
   | Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } -> ()
   | other -> failf "expected Unknown_invalid_request for prose-only 400, got %s" (Retry.error_message other));
  (* Structured HTTP 403/429 quota/billing exhaustion (OpenRouter key_limit_exceeded,
     OpenCode Go GoUsageLimitError, 403 with Retry-After). *)
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:(Some 1092006.0)
       ~status:429
       ~body:{|{"type":"error","error":{"type":"GoUsageLimitError","message":"Monthly usage limit reached"}}|}
   with
   | Some (Retry.Structured_account_quota { retry_after = Some 1092006.0; _ }) -> ()
   | _ -> fail "expected Structured_account_quota with retry_after for GoUsageLimitError");
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:403
       ~body:{|{"error":{"code":"key_limit_exceeded","message":"Key limit exceeded"}}|}
   with
   | Retry.PaymentRequired _ -> ()
   | other -> failf "expected PaymentRequired for 403 key_limit_exceeded, got %s" (Retry.error_message other));
  (* A 403 carrying Retry-After with NO structured quota/billing signal (e.g. WAF/CDN)
     must stay AuthorizationError, never stamped as PaymentRequired/Structured_account_quota. *)
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:(Some 60.0)
       ~status:403
       ~body:{|{"error":{"message":"Forbidden by edge WAF"}}|}
   with
   | None -> ()
   | Some _ -> fail "403 with Retry-After only must not classify as Structured_account_quota");
  (match
     Retry.classify_error
       ~retry_after_header:(Some 60.0)
       ~status:403
       ~body:{|{"error":{"message":"Forbidden by edge WAF"}}|}
   with
   | Retry.AuthorizationError _ -> ()
   | other -> failf "expected AuthorizationError for 403+Retry-After without quota signal, got %s" (Retry.error_message other));
  (* Ordinary transient Gemini RPM/TPM HTTP 429 carries gRPC status
     RESOURCE_EXHAUSTED without billing/quota details[].reason and must stay
     RateLimited rather than Hard_quota. *)
  let gemini_transient_429 =
    {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Resource has been exhausted (e.g. check quota)."}}|}
  in
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:None
       ~status:429
       ~body:gemini_transient_429
   with
   | None -> ()
   | Some _ -> fail "transient Gemini RESOURCE_EXHAUSTED 429 must not classify as Structured_account_quota");
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:429
       ~body:gemini_transient_429
   with
   | Retry.RateLimited _ -> ()
   | other -> failf "expected RateLimited for transient Gemini 429, got %s" (Retry.error_message other));
  (* Explicit Gemini quota/billing detail reason still classifies as account quota. *)
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:None
       ~status:429
       ~body:{|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"reason":"BILLING_DISABLED"}]}}|}
   with
   | Some (Retry.Structured_account_quota _) -> ()
   | _ -> fail "expected Structured_account_quota for explicit BILLING_DISABLED detail reason")
;;

let test_zai_glm_error_codes_require_glm_codec () =
  let module Glm = Llm_provider.Backend_glm in
  let quota_codes =
    [ "1113"; "1308"; "1309"; "1310"; "1311"; "1313"; "1314"
    ; "1316"; "1317"; "1318"; "1319"; "1320"; "1321"
    ]
  in
  List.iter
    (fun code ->
       check bool (Printf.sprintf "Backend_glm.is_quota_code %s" code) true
         (Glm.is_quota_code code);
       check bool (Printf.sprintf "Backend_glm.is_context_overflow_code %s" code) false
         (Glm.is_context_overflow_code code);
       let body = Printf.sprintf {|{"error":{"code":%S,"message":"quota exhausted"}}|} code in
       (match Glm.check_glm_error body with
        | Some { error_class = Some Glm.Glm_quota_exceeded; _ } -> ()
        | Some _ | None -> failf "GLM codec must read Z.AI code %s as quota" code);
       (match Retry.classify_structured_refusal ~retry_after_header:None ~status:429 ~body with
        | None -> ()
        | Some _ -> failf "Z.AI code %s read by the provider-neutral HTTP tables" code);
       match Retry.classify_structured_json (Yojson.Safe.from_string body) with
       | None -> ()
       | Some _ -> failf "Z.AI code %s read by the shared structured classifier" code)
    quota_codes;
  check bool "Backend_glm.is_context_overflow_code 1261" true
    (Glm.is_context_overflow_code "1261");
  check bool "Backend_glm.is_quota_code 1261" false (Glm.is_quota_code "1261");
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"code":"1261","message":"Prompt exceeds max length"}}|}
   with
   | None -> ()
   | Some _ -> fail "Z.AI code 1261 read by the provider-neutral HTTP tables");
  (match
     Glm.check_glm_error {|{"error":{"code":"1261","message":"Prompt exceeds max length"}}|}
   with
   | Some { error_class = Some Glm.Glm_context_overflow; _ } -> ()
   | Some _ | None -> fail "GLM codec must read Z.AI code 1261 as context overflow");
  (match
     Retry.classify_structured_json
       (Yojson.Safe.from_string {|{"error":{"code":"1261","message":"Prompt exceeds max length"}}|})
   with
   | None -> ()
   | Some _ -> fail "Z.AI code 1261 read by the shared structured classifier");
  List.iter
    (fun code ->
       check bool (Printf.sprintf "non-quota transient Z.AI code %s" code) false
         (Glm.is_quota_code code);
       check bool (Printf.sprintf "non-overflow Z.AI code %s" code) false
         (Glm.is_context_overflow_code code);
       let body = Printf.sprintf {|{"error":{"code":%S,"message":"transient"}}|} code in
       match Retry.classify_structured_refusal ~retry_after_header:None ~status:429 ~body with
       | None -> ()
       | Some _ -> failf "transient Z.AI code %s must not classify as hard quota" code)
    [ "1302"; "1305" ]
;;

let test_http_400_requires_structured_quota_evidence () =
  let prose_bodies =
    [ {|{"type":"error","error":{"type":"invalid_request_error","param":"workspace spend limit","message":"unknown input field workspace spend limit"}}|}
    ; {|{"error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}|}
    ; {|{"error":{"type":"invalid_request_error","message":"You have reached your specified API usage limits."}}|}
    ]
  in
  List.iter
    (fun body ->
       match Retry.classify_error ~retry_after_header:None ~status:400 ~body with
       | Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } -> ()
       | other -> failf "expected Unknown_invalid_request, got %s" (Retry.error_message other))
    prose_bodies;
  match
    Retry.classify_error
      ~retry_after_header:None
      ~status:400
      ~body:{|{"error":{"code":"credit_balance_too_low","message":"billing refused"}}|}
  with
  | Retry.PaymentRequired _ -> ()
  | other -> failf "expected PaymentRequired, got %s" (Retry.error_message other)
;;

let test_structured_json_signals_and_status_optional_ssot () =
  let parse s = Yojson.Safe.from_string s in
  (* 1. http_status_of_json ignores JSON-RPC negative codes and vendor codes > 599 *)
  check (option int) "JSON-RPC -32000 is not an HTTP status" None
    (Retry.http_status_of_json (parse {|{"code":-32000,"message":"internal"}|}));
  check (option int) "Z.AI code 1113 is not an HTTP status" None
    (Retry.http_status_of_json (parse {|{"error":{"code":1113,"message":"quota"}}|}));
  check (option int) "explicit httpStatus 429 extracted" (Some 429)
    (Retry.http_status_of_json (parse {|{"httpStatus":429,"status":"RESOURCE_EXHAUSTED"}|}));
  check (option int) "nested metadata.raw code 503 extracted" (Some 503)
    (Retry.http_status_of_json
       (parse {|{"error":{"metadata":{"raw":"{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}"}}}|}));
  (* 2. retry_after_of_json supports snake_case + camelCase and rejects negatives *)
  check (option (float 0.001)) "camelCase retryAfter extracted" (Some 42.5)
    (Retry.retry_after_of_json (parse {|{"error":{"retryAfter":42.5}}|}));
  check (option (float 0.001)) "negative retry_after rejected" None
    (Retry.retry_after_of_json (parse {|{"error":{"retry_after":-3.0}}|}));
  (* 3. Status-optional structured JSON classification *)
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"error_code":"context_length_exceeded","n_ctx":400000,"message":"cap hit"}}|})
   with
   | Some (Retry.Signal_context_overflow { limit = Some 400000; message = "cap hit" }) -> ()
   | _ -> fail "expected Signal_context_overflow from error_code without HTTP status");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","retryAfter":15,"message":"rpm"}}|})
   with
   | Some (Retry.Signal_rate_limited { retry_after = Some 15.0; _ }) -> ()
   | _ -> fail "Gemini transient 429 RESOURCE_EXHAUSTED must classify as Signal_rate_limited");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"reason":"QUOTA_EXCEEDED"}],"retry_after":600}}|})
   with
   | Some (Retry.Signal_hard_quota { retry_after = Some 600.0; _ }) -> ()
   | _ -> fail "Gemini 429 with QUOTA_EXCEEDED detail must classify as Signal_hard_quota");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"status":"UNAUTHENTICATED","message":"bad token"}}|})
   with
   | Some (Retry.Signal_auth_error { message = "bad token" }) -> ()
   | _ -> fail "UNAUTHENTICATED must classify as Signal_auth_error");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"status":"PERMISSION_DENIED","message":"denied"}}|})
   with
   | Some (Retry.Signal_authorization_error { message = "denied" }) -> ()
   | _ -> fail "PERMISSION_DENIED must classify as Signal_authorization_error");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"type":"overloaded_error","message":"busy"}}|})
   with
   | Some (Retry.Signal_provider_unavailable { message = "busy" }) -> ()
   | _ -> fail "overloaded_error must classify as Signal_provider_unavailable");
  (* 4. Free-form prose in message without structured codes MUST return None (zero prose guessing) *)
  (match
     Retry.classify_structured_json
       (parse {|{"message":"permission denied while reading token limit file (throttled/overloaded/forbidden)"}|})
   with
   | None -> ()
   | Some _ -> fail "prose-only JSON without structured codes must stay unclassified (None)");
  (* 5. structured_refusal_of_json matches classify_structured_refusal without re-serializing *)
  (match
     Retry.structured_refusal_of_json
       ~retry_after:30.0
       ~status:429
       (parse {|{"error":{"type":"GoUsageLimitError","message":"monthly limit"}}|})
   with
   | Some (Retry.Structured_account_quota { retry_after = Some 30.0; message = "monthly limit" }) -> ()
   | _ -> fail "structured_refusal_of_json must match GoUsageLimitError");
  (* 6. P1 fixes: outer-object + nested error merge, flat-string error message, status-field overflow/quota *)
  (match
     Retry.classify_structured_json
       (parse {|{"error_code":"context_length_exceeded","n_ctx":200000,"error":{"message":"cap hit"}}|})
   with
   | Some (Retry.Signal_context_overflow { limit = Some 200000; message = "cap hit" }) -> ()
   | _ -> fail "outer error_code + n_ctx must merge with nested error.message");
  (match
     Retry.classify_structured_json
       (parse {|{"status":"RESOURCE_EXHAUSTED","error":{"message":"slow down"}}|})
   with
   | Some (Retry.Signal_rate_limited { message = "slow down"; retry_after = None }) -> ()
   | _ -> fail "outer status RESOURCE_EXHAUSTED must merge with nested error");
  (match
     Retry.classify_structured_json
       ~http_status:429
       (parse {|{"error":"too many concurrent requests"}|})
   with
   | Some (Retry.Signal_rate_limited { message = "too many concurrent requests"; _ }) -> ()
   | _ -> fail "flat-string error field must preserve message");
  (match
     Retry.structured_refusal_of_json
       ~status:400
       (parse {|{"error":"Your credit balance is too low"}|})
   with
   | None -> ()
   | Some _ -> fail "a flat-string billing description must not classify HTTP 400");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"status":"context_length_exceeded","message":"too long"}}|})
   with
   | Some (Retry.Signal_context_overflow { message = "too long"; _ }) -> ()
   | _ -> fail "status-field context_length_exceeded must classify");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"status":"QUOTA_EXCEEDED","message":"budget spent"}}|})
   with
   | Some (Retry.Signal_hard_quota { message = "budget spent"; _ }) -> ()
   | _ -> fail "status-field QUOTA_EXCEEDED must classify");
  (* 7. P2 fixes: caller ?retry_after sanitization and non-refusal ?http_status fallback *)
  check (option (float 0.001)) "retry_after_of_json rejects NaN/Inf" None
    (Retry.retry_after_of_json (`Assoc [ "retry_after", `Float Float.nan ]));
  check (option (float 0.001)) "retry_after_of_json rejects +Inf" None
    (Retry.retry_after_of_json (`Assoc [ "retry_after", `Float Float.infinity ]));
  check (option (float 0.001)) "retry_after_of_json rejects overflowing Intlit" None
    (Retry.retry_after_of_json (`Assoc [ "retry_after", `Intlit (String.make 400 '9') ]));
  (match
     Retry.classify_structured_json
       ~retry_after:Float.infinity
       (parse {|{"error":{"code":429,"retry_after":-3.0,"message":"rpm"}}|})
   with
   | Some (Retry.Signal_rate_limited { retry_after = None; _ }) -> ()
   | _ -> fail "non-finite caller retry_after must sanitize to None");
  (match
     Retry.structured_refusal_of_json ~retry_after:(-5.0) ~status:402 (`Assoc [])
   with
   | Some (Retry.Structured_account_quota { retry_after = None; _ }) -> ()
   | _ -> fail "negative caller retry_after must sanitize to None");
  (match
     Retry.classify_structured_json
       ~http_status:200
       (parse {|{"error":{"code":402,"message":"Insufficient Balance"}}|})
   with
   | Some (Retry.Signal_hard_quota { message = "Insufficient Balance"; _ }) -> ()
   | _ -> fail "non-refusal caller http_status 200 must not shadow JSON status 402");
  (match
     Retry.classify_structured_json
       ~http_status:(-32000)
       (parse {|{"error":{"code":503,"message":"down"}}|})
   with
   | Some (Retry.Signal_provider_unavailable { message = "down" }) -> ()
   | _ -> fail "negative JSON-RPC caller status must not shadow JSON status 503");
  (* Trim codes before applying the shared table. *)
  let code_signals code =
    { Retry.codes = [ code ]
    ; types = []
    ; statuses = []
    ; detail_reasons = []
    ; messages = []
    ; n_ctx = None
    }
  in
  check bool "trimmed insufficient_quota recognized" true
    (Retry.signals_indicate_account_quota (code_signals " insufficient_quota "));
  check bool "unscoped Z.AI code 1113 leaves quota unclassified" false
    (Retry.signals_indicate_account_quota (code_signals " 1113 "));
  check (option int) "non-object JSON returns None status" None
    (Retry.http_status_of_json (`List [ `Int 429 ]));
  (match Retry.classify_structured_json ~fallback_message:"fb" (`Assoc [ "code", `Int 401 ]) with
   | Some (Retry.Signal_auth_error { message = "fb" }) -> ()
   | _ -> fail "fallback_message must be used when JSON has no message field");
  (* metadata.raw recursion depth boundary: depth 2 extracted, depth 3 cut off *)
  let wrap_raw inner =
    Yojson.Safe.to_string (`Assoc [ "metadata", `Assoc [ "raw", `String inner ] ])
  in
  let leaf = {|{"error":{"code":503,"retry_after":9}}|} in
  let depth_2 = parse (wrap_raw (wrap_raw leaf)) in
  let depth_3 = parse (wrap_raw (wrap_raw (wrap_raw leaf))) in
  check (option int) "metadata.raw depth 2 extracted" (Some 503)
    (Retry.http_status_of_json depth_2);
  check (option (float 0.001)) "metadata.raw depth 2 retry_after extracted" (Some 9.0)
    (Retry.retry_after_of_json depth_2);
  check (option int) "metadata.raw depth 3 cut off" None
    (Retry.http_status_of_json depth_3);
  check (option (float 0.001)) "metadata.raw depth 3 retry_after cut off" None
    (Retry.retry_after_of_json depth_3);
  (* Descriptive billing text carries no structured HTTP 400 reason. *)
  (match
     Retry.classify_structured_json
       ~http_status:400
       (parse {|{"error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}|})
   with
   | None -> ()
   | Some _ -> fail "a billing description must not classify the structured HTTP 400");
  (* 9. classify_embedded_json and classify_machine_tokens SSOT *)
  (match
     Retry.classify_embedded_json
       {|upstream failure: {"error":{"code":"context_length_exceeded","n_ctx":128000}} (aborted)|}
   with
   | Some (Retry.Signal_context_overflow { limit = Some 128000; _ }) -> ()
   | _ -> fail "classify_embedded_json must extract balanced JSON with trailing text");
  (match
     Retry.classify_embedded_json
       {|{unbalanced prefix {"error":{"code":"context_length_exceeded","n_ctx":64000}}|}
   with
   | Some (Retry.Signal_context_overflow { limit = Some 64000; _ }) -> ()
   | _ -> fail "classify_embedded_json must survive an unbalanced '{' prefix");
  (match
     Retry.classify_embedded_json
       {|[{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"rpm"}}]|}
   with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "classify_embedded_json must classify bare Gemini JSON-array error envelope");
  (match
     Retry.classify_embedded_json
       {|{"message":"user quoted {\"error\":{\"code\":429}} in prose"}|}
   with
   | None -> ()
   | Some _ -> fail "classify_embedded_json must not re-scan prose strings inside a valid JSON object");
  (match Retry.classify_machine_tokens "http: HTTP 429" with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "http prefix within 12 bytes must not mask subsequent HTTP 429");
  (match Retry.classify_machine_tokens "http-gw: HTTP 503" with
   | Some (Retry.Signal_provider_unavailable _) -> ()
   | _ -> fail "http-gw prefix within 12 bytes must not mask subsequent HTTP 503");
  (match Retry.classify_machine_tokens "exceeded_current_quota_error: credits exhausted" with
   | Some (Retry.Signal_hard_quota _) -> ()
   | _ -> fail "exact token exceeded_current_quota_error must classify as hard quota");
  (match Retry.classify_machine_tokens "RESOURCE_EXHAUSTED: slow down" with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "RESOURCE_EXHAUSTED alone must classify as rate limited");
  (match Retry.classify_machine_tokens "RESOURCE_EXHAUSTED: QUOTA_EXCEEDED" with
   | Some (Retry.Signal_hard_quota _) -> ()
   | _ -> fail "RESOURCE_EXHAUSTED + QUOTA_EXCEEDED must classify as hard quota");
  (match Retry.classify_machine_tokens "HTTP 429 Too Many Requests: request too large" with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "HTTP 429 must classify as rate limited");
  (match Retry.classify_machine_tokens "HTTP/1.1 503 Service Unavailable" with
   | Some (Retry.Signal_provider_unavailable _) -> ()
   | _ -> fail "HTTP/1.1 503 must classify as provider unavailable");
  (match Retry.classify_machine_tokens "HTTP/2 401 Unauthorized" with
   | Some (Retry.Signal_auth_error _) -> ()
   | _ -> fail "HTTP/2 401 must classify as auth error");
  (match Retry.classify_machine_tokens "context_length_exceeded: max input" with
   | Some (Retry.Signal_context_overflow _) -> ()
   | _ -> fail "exact token context_length_exceeded must classify as overflow");
  (* Zero English prose false positives *)
  List.iter
    (fun prose ->
       match Retry.classify_machine_tokens prose with
       | None -> ()
       | Some _ -> failf "free-form prose must stay unclassified: %S" prose)
    [ "permission denied reading /tmp/file"
    ; "forbidden character in tool argument"
    ; "prompt exceeds maximum context length"
    ; "token limit discussed in user message"
    ; "service throttled or overloaded in simulation"
    ; "port 429 refused connection on line 503"
    ; "HTTP request on port 429 failed"
    ; "HTTP 400 Bad Request"
    ; "HTTP 500-byte chunk"
    ; "HTTP 403/404 ratio"
    ; "HTTP 4290 malformed code"
    ; "bare QUOTA_EXHAUSTED prose without reason= key"
    ; "my_reason=QUOTA_EXHAUSTED wrong key prefix"
    ; "reason=QUOTA_EXHAUSTED_EXTRA suffix"
    ];
  (* 10. Cross-model review hardening: google.rpc.RetryInfo, 400/422 parity,
     HTTP 413 separation, reason=QUOTA_EXHAUSTED, and Retry.classify_text SSOT *)
  check (option (float 0.001)) "google.rpc.RetryInfo integer retryDelay parsed" (Some 39.0)
    (Retry.retry_after_of_json
       (parse
          {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"39s"}]}}|}));
  check (option (float 0.001)) "google.rpc.RetryInfo fractional retryDelay parsed" (Some 12.5)
    (Retry.retry_after_of_json
       (parse
          {|{"error":{"details":[{"@type":"google.rpc.RetryInfo","retryDelay":"12.5s"}]}}|}));
  check (option (float 0.001)) "numeric retry_after takes precedence over RetryInfo" (Some 7.0)
    (Retry.retry_after_of_json
       (parse
          {|{"error":{"retry_after":7,"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"39s"}]}}|}));
  List.iter
    (fun bad ->
       check (option (float 0.001)) ("invalid RetryInfo duration rejected: " ^ bad) None
         (Retry.retry_after_of_json
            (`Assoc
               [ ( "details"
                 , `List
                     [ `Assoc
                         [ "@type", `String "type.googleapis.com/google.rpc.RetryInfo"
                         ; "retryDelay", `String bad
                         ]
                     ] )
               ])))
    [ "-5s"; "39"; ".5s"; "39.s"; "1e3s"; ""; "abc" ];
  (* 400/422 precedence parity with structured_refusal_of_signals (overflow > quota) *)
  (match
     Retry.classify_structured_json
       ~http_status:400
       (parse
          {|{"error":{"code":"context_length_exceeded","n_ctx":64000,"details":[{"reason":"QUOTA_EXCEEDED"}]}}|} )
   with
   | Some (Retry.Signal_context_overflow { limit = Some 64000; _ }) -> ()
   | _ -> fail "HTTP 400 must preserve structured_refusal_of_signals overflow > quota parity");
  (* HTTP 413 separates into Signal_request_body_too_large (never fabricates context overflow) *)
  (match
     Retry.classify_structured_json
       ~http_status:413
       (parse {|{"error":{"message":"payload too large","n_ctx":128000}}|} )
   with
   | Some (Retry.Signal_request_body_too_large _) -> ()
   | _ -> fail "HTTP 413 must classify as Signal_request_body_too_large, not context overflow");
  (match Retry.classify_text {|HTTP 413 Payload Too Large: {"error":{"code":"request_too_large"}}|} with
   | Some (Retry.Signal_request_body_too_large _) -> ()
   | _ -> fail "HTTP 413 text must classify as Signal_request_body_too_large");
  (* P1 invariant: HTTP 429/401/402/403 in text NEVER downgraded to Signal_context_overflow *)
  (match
     Retry.classify_text
       {|HTTP 429 Too Many Requests: {"error":{"code":"request_too_large"}}|}
   with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "HTTP 429 in message text must take precedence over embedded request_too_large JSON");
  (match
     Retry.classify_text
       {|HTTP 403 Forbidden: {"error":{"code":"context_length_exceeded"}}|}
   with
   | Some (Retry.Signal_authorization_error _) -> ()
   | _ -> fail "HTTP 403 in message text must not misclassify as context overflow");
  (* Leading unrelated JSON object must not mask later quota JSON under caller HTTP 429 *)
  (match
     Retry.classify_text
       ~http_status:429
       {|{"requestId":"req-1"} {"error":{"details":[{"reason":"QUOTA_EXCEEDED"}]}}|}
   with
   | Some (Retry.Signal_hard_quota _) -> ()
   | _ -> fail "leading unrelated JSON must not prevent later quota JSON promotion under HTTP 429");
  (* Exact reason=QUOTA_EXHAUSTED vs bare RESOURCE_EXHAUSTED boundary + RetryInfo preservation *)
  (match
     Retry.classify_text
       "You have exhausted your capacity on this model. Your quota will reset after 4h41m7s. reason=QUOTA_EXHAUSTED"
   with
   | Some (Retry.Signal_hard_quota _) -> ()
   | _ -> fail "exact key=value reason=QUOTA_EXHAUSTED must classify as Signal_hard_quota");
  (match
     Retry.classify_text
       {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"39s"}]}} reason=QUOTA_EXHAUSTED|}
   with
   | Some (Retry.Signal_hard_quota { retry_after = Some 39.0; _ }) -> ()
   | _ -> fail "reason=QUOTA_EXHAUSTED with RetryInfo must preserve 39.0s retry_after");
  check (option int) "http_status_of_machine_tokens extracts 429 and rejects 4290" (Some 429)
    (Retry.http_status_of_machine_tokens "HTTP 429 Too Many Requests");
  check (option int) "http_status_of_machine_tokens rejects 4290" None
    (Retry.http_status_of_machine_tokens "HTTP 4290 invalid");
  (* 16 KiB boundary truncation must not synthesize a partial prefix wire token
     (use non-whitespace '.' filler so String.trim does not strip the prefix). *)
  let boundary_payload = String.make 16366 '.' ^ "insufficient_quota_unrelated_suffix" in
  (match Retry.classify_machine_tokens boundary_payload with
   | None -> ()
   | Some _ -> fail "16 KiB token boundary must not fabricate insufficient_quota from truncated suffix");
  (* 11. HTTP classify_error / classify_structured_refusal behavioral invariance:
     wider non-HTTP/ACP codes (prompt_too_long, payment_required, status-field
     matches, outer-object merges) must NOT alter existing HTTP classify_error
     decisions while still classifying through classify_structured_json. *)
  (match
     Retry.classify_error
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"code":"prompt_too_long","message":"too long"}}|}
   with
   | Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ } -> ()
   | other ->
     failf "HTTP 400 code=prompt_too_long must remain Unknown_invalid_request, got %s"
       (Retry.error_message other));
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:None
       ~status:400
       ~body:{|{"error":{"code":"payment_required","message":"pay"}}|}
   with
   | None -> ()
   | Some _ -> fail "HTTP 400 code=payment_required must remain unchanged (None) in classify_structured_refusal");
  (match
     Retry.classify_structured_refusal
       ~retry_after_header:None
       ~status:403
       ~body:{|{"error":{"status":"QUOTA_EXCEEDED","message":"spent"}}|}
   with
   | None -> ()
   | Some _ -> fail "HTTP 403 status=QUOTA_EXCEEDED must remain unchanged (None) in classify_structured_refusal");
  (match
     Retry.classify_structured_json
       (parse {|{"error":{"code":"prompt_too_long","message":"too long"}}|})
   with
   | Some (Retry.Signal_context_overflow _) -> ()
   | _ -> fail "non-HTTP classify_structured_json must still classify code=prompt_too_long")
;;

let () =
  run
    "Retry"
    [ ( "classify"
      , [ test_case "http status mapping" `Quick test_classify_error
        ; test_case "Z.AI numeric error codes require the GLM codec" `Quick
            test_zai_glm_error_codes_require_glm_codec
        ; test_case "HTTP 400 quota requires structured evidence" `Quick
            test_http_400_requires_structured_quota_evidence
        ; test_case "structured JSON signals and status-optional SSOT" `Quick
            test_structured_json_signals_and_status_optional_ssot
        ; test_case "edge cases" `Quick test_classify_error_edge_cases
        ; test_case
            "structured 400/422 overflow and 403/429 quota"
            `Quick
            test_structured_refusal_classification
        ; test_case
            "server refusal status boundaries"
            `Quick
            test_server_refusal_status_boundaries
        ; test_case
            "a refusal body that never arrived is not an empty body"
            `Quick
            test_a_refusal_body_that_never_arrived_is_not_an_empty_body
        ; test_case "402 payment required" `Quick test_classify_error_402_payment_required
        ; test_case
            "403 authorization denied"
            `Quick
            test_classify_error_403_authorization_denied
        ; test_case
            "429 retry_after finite guard"
            `Quick
            test_classify_error_429_retry_after_finite_guard
        ; test_case
            "429 retry_after JSON numbers"
            `Quick
            test_classify_error_429_retry_after_json_numbers
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
        ; test_case
            "a status no arm names keeps its own reason"
            `Quick
            test_unclassified_status_keeps_its_own_reason
        ; test_case "error_message all variants" `Quick test_error_message_all_variants
        ] )
    ]
;;
