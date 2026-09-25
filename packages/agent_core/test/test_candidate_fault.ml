(* Table test for Candidate_fault. See RFC-one-slot-fault-judgment-for-every-walk.md
   §4 step 1: the expected judgment is written in its own wildcard-free match,
   so a new [Retry.api_error] constructor stops compilation here until the
   expected value is chosen and reviewed. *)

(* The expected judgment for every [Retry.api_error] constructor, RFC §3. *)
let expected_of_api_error (api : Llm_provider.Retry.api_error)
  : Llm_provider.Candidate_fault.t
  =
  match api with
  | Llm_provider.Retry.RateLimited _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Rate_limit
  | Llm_provider.Retry.Overloaded _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Capacity
  | Llm_provider.Retry.ServerError _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Server
  | Llm_provider.Retry.AuthError _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Credential
  | Llm_provider.Retry.AuthorizationError _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Credential
  | Llm_provider.Retry.PaymentRequired _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Account
  | Llm_provider.Retry.NotFound _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Model_absent
  | Llm_provider.Retry.ContextOverflow _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Window
  | Llm_provider.Retry.InputCapacity _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Admission
  | Llm_provider.Retry.InvalidRequest { reason; _ } ->
    (match reason with
     | Llm_provider.Retry.Request_body_refused_by_provider _ ->
       Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Body_limit
     | Llm_provider.Retry.Refusal_body_not_received ->
       Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Refusal_unread
     | Llm_provider.Retry.Attempt_rejected ->
       Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Admission
     | Llm_provider.Retry.Json_parse_error ->
       Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Admission
     | Llm_provider.Retry.Unknown_invalid_request ->
       Llm_provider.Candidate_fault.Unattributed)
  | Llm_provider.Retry.NetworkError _ ->
    Llm_provider.Candidate_fault.Unknown_after_dispatch
  | Llm_provider.Retry.Timeout _ ->
    Llm_provider.Candidate_fault.Binding Llm_provider.Candidate_fault.Deadline
;;

let ordinal_of_binding (b : Llm_provider.Candidate_fault.binding_fact) : int =
  match b with
  | Llm_provider.Candidate_fault.Credential -> 0
  | Llm_provider.Candidate_fault.Account -> 1
  | Llm_provider.Candidate_fault.Model_absent -> 2
  | Llm_provider.Candidate_fault.Rate_limit -> 3
  | Llm_provider.Candidate_fault.Capacity -> 4
  | Llm_provider.Candidate_fault.Server -> 5
  | Llm_provider.Candidate_fault.Window -> 6
  | Llm_provider.Candidate_fault.Body_limit -> 7
  | Llm_provider.Candidate_fault.Admission -> 8
  | Llm_provider.Candidate_fault.Deadline -> 9
  | Llm_provider.Candidate_fault.Output_dialect -> 10
  | Llm_provider.Candidate_fault.Refusal_unread -> 11
;;

let ordinal (t : Llm_provider.Candidate_fault.t) : int =
  match t with
  | Llm_provider.Candidate_fault.Binding b -> ordinal_of_binding b
  | Llm_provider.Candidate_fault.Unattributed -> 100
  | Llm_provider.Candidate_fault.Unknown_after_dispatch -> 101
;;

let assert_api name api =
  let expected = expected_of_api_error api in
  let actual = Llm_provider.Candidate_fault.of_api_error api in
  if actual <> expected
  then
    failwith
      (Printf.sprintf
         "%s: Candidate_fault.of_api_error = %d, expected %d"
         name
         (ordinal actual)
         (ordinal expected))
;;

let serving_constraint () =
  match
    Llm_provider.Serving_constraint.make
      ~source_kind:Llm_provider.Serving_constraint.Declaration
      ~source_ref:"test"
      ~checked_at_unix_s:0
      ~confidence:Llm_provider.Serving_constraint.High
      ~expires_at_unix_s:3600
      ~accepted_through:1000
      ()
  with
  | Ok c -> c
  | Error _ -> failwith "serving_constraint make failed"
;;

let api_cases : (string * Llm_provider.Retry.api_error) list =
  [ "rate_limited", Llm_provider.Retry.RateLimited { retry_after = None; message = "" }
  ; "overloaded", Llm_provider.Retry.Overloaded { message = "" }
  ; "server_error", Llm_provider.Retry.ServerError { status = 500; message = "" }
  ; "auth_error", Llm_provider.Retry.AuthError { message = "" }
  ; "authorization_error", Llm_provider.Retry.AuthorizationError { message = "" }
  ; "payment_required", Llm_provider.Retry.PaymentRequired { message = "" }
  ; "not_found", Llm_provider.Retry.NotFound { message = "" }
  ; "context_overflow", Llm_provider.Retry.ContextOverflow { message = ""; limit = None }
  ; ( "input_capacity"
    , Llm_provider.Retry.InputCapacity
        { message = ""
        ; constraint_ = serving_constraint ()
        ; reason =
            Llm_provider.Retry.Token_measurement_unavailable
              Llm_provider.Input_token_count.Anthropic_messages_count_tokens
        } )
  ; ( "body_refused"
    , Llm_provider.Retry.InvalidRequest
        { message = ""
        ; reason = Llm_provider.Retry.Request_body_refused_by_provider { status = 413 }
        } )
  ; ( "refusal_unread"
    , Llm_provider.Retry.InvalidRequest
        { message = ""; reason = Llm_provider.Retry.Refusal_body_not_received } )
  ; ( "attempt_rejected"
    , Llm_provider.Retry.InvalidRequest
        { message = ""; reason = Llm_provider.Retry.Attempt_rejected } )
  ; ( "json_parse"
    , Llm_provider.Retry.InvalidRequest
        { message = ""; reason = Llm_provider.Retry.Json_parse_error } )
  ; ( "unknown_invalid"
    , Llm_provider.Retry.InvalidRequest
        { message = ""; reason = Llm_provider.Retry.Unknown_invalid_request } )
  ; ( "network_error"
    , Llm_provider.Retry.NetworkError
        { message = ""; kind = Llm_provider.Http_client.Connection_refused } )
  ; "timeout", Llm_provider.Retry.Timeout { message = ""; phase = None }
  ]
;;

let run () =
  List.iter (fun (name, api) -> assert_api name api) api_cases;
  print_endline "test_candidate_fault: OK"
;;

run ()
