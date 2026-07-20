module F = Masc.Keeper_board_attention_failure
module Route = Keeper_runtime_failure_route

let ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
;;

let test_provider_retry_after_is_exact_authority () =
  let failure =
    F.of_sdk_error
      ~observed_at:100.0
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.RateLimited
            { retry_after = Some 30.0; message = "typed throttle" }))
  in
  match failure with
  | F.Retryable retryable ->
    (match retryable.requirement with
     | F.Provider_retry_after { retry_class = Route.Rate_limited; delay_seconds } ->
       Alcotest.(check (float 0.0)) "exact Provider delay" 30.0 delay_seconds
     | F.Provider_retry_after _
     | F.Provider_recovery _
     | F.Runtime_catalog_change _
     | F.Runtime_configuration_change ->
       Alcotest.fail "typed rate limit lost its retry-after authority");
    Alcotest.(check (option (float 0.0)))
      "exact derived deadline"
      (Some 130.0)
      (F.retry_deadline retryable);
    Alcotest.(check bool)
      "retry evidence roundtrip"
      true
      (ok
         "decode retry evidence"
         (F.retryable_of_yojson (F.retryable_to_yojson retryable))
       = retryable)
  | F.Blocked _ -> Alcotest.fail "valid Provider retry-after was blocked"
;;

let test_missing_provider_hint_requires_recovery_signal () =
  match
    F.of_sdk_error
      ~observed_at:100.0
      (Agent_sdk.Error.Provider
         (Llm_provider.Error.ProviderUnavailable
            { provider = "typed-provider"; detail = "upstream unavailable" }))
  with
  | F.Retryable
      { requirement = F.Provider_recovery Route.Server_error
      ; failed_at
      ; _
      } ->
    Alcotest.(check (float 0.0)) "observation time" 100.0 failed_at
  | F.Retryable _ | F.Blocked _ ->
    Alcotest.fail "hintless Provider outage invented a retry deadline"
;;

let test_deterministic_sdk_failure_is_blocked () =
  let failure =
    F.of_sdk_error
      ~observed_at:100.0
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.InvalidRequest
            { message = "invalid schema"
            ; reason = Llm_provider.Retry.Unknown_invalid_request
            }))
  in
  match failure with
  | F.Blocked
      ({ kind =
           F.Provider_judgment_required
             { judgment = Route.Deterministic_request
             ; provenance = Route.Oas_api_error
             }
       ; _
       } as blocked) ->
    Alcotest.(check bool)
      "blocked evidence roundtrip"
      true
      (ok
         "decode blocked evidence"
         (F.blocked_of_yojson (F.blocked_to_yojson blocked))
       = blocked)
  | F.Blocked _ | F.Retryable _ ->
    Alcotest.fail "deterministic SDK failure was not typed as blocked"
;;

let test_invalid_provider_hint_fails_closed () =
  match
    F.of_sdk_error
      ~observed_at:100.0
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.RateLimited
            { retry_after = Some (-1.0); message = "invalid typed hint" }))
  with
  | F.Blocked { kind = F.Invalid_provider_retry_authority; _ } -> ()
  | F.Blocked _ | F.Retryable _ ->
    Alcotest.fail "invalid Provider retry authority did not fail closed"
;;

let test_retry_codec_rejects_unknown_requirement () =
  let malformed =
    `Assoc
      [ ( "requirement"
        , `Assoc [ "kind", `String "elapsed_time_guess" ] )
      ; "detail", `String "must not decode"
      ; "failed_at", `Float 1.0
      ]
  in
  expect_error "unknown retry requirement" (F.retryable_of_yojson malformed)
;;

let () =
  Alcotest.run
    "keeper_board_attention_failure"
    [ ( "typed retry authority"
      , [ Alcotest.test_case
            "Provider retry-after is exact authority"
            `Quick
            test_provider_retry_after_is_exact_authority
        ; Alcotest.test_case
            "missing hint requires Provider recovery"
            `Quick
            test_missing_provider_hint_requires_recovery_signal
        ; Alcotest.test_case
            "deterministic SDK failure is blocked"
            `Quick
            test_deterministic_sdk_failure_is_blocked
        ; Alcotest.test_case
            "invalid Provider hint fails closed"
            `Quick
            test_invalid_provider_hint_fails_closed
        ; Alcotest.test_case
            "unknown retry requirement is rejected"
            `Quick
            test_retry_codec_rejects_unknown_requirement
        ] )
    ]
;;
