(** Mapping tests for [Keeper_runtime_attempt.core_error_to_runtime_outcome].

    Pins the 429 reconstruction boundary: the resolved [retry_after] on
    [Llm_provider.Retry.RateLimited] must re-enter through
    [HttpError.retry_after_header] instead of being dropped. Both 0.216
    adaptation passes on 2026-07-17 (#25082, #25084) discarded it with a
    [{ message; _ }] pattern, so this mapping is fenced by test. *)

module KRA = Masc.Keeper_runtime_attempt

let retry_after_of_outcome = function
  | Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.HttpError { code = 429; retry_after_header; _ })) ->
    Some retry_after_header
  | _ -> None

let rate_limited retry_after =
  Agent_core.Error.Api (Llm_provider.Retry.RateLimited { message = "slow down"; retry_after })

let test_429_threads_resolved_retry_after () =
  Alcotest.(check (option (option (float 0.0))))
    "resolved retry-after re-enters via the header slot"
    (Some (Some 42.0))
    (retry_after_of_outcome (KRA.core_error_to_runtime_outcome (rate_limited (Some 42.0))))

let test_429_without_hint_stays_none () =
  Alcotest.(check (option (option (float 0.0))))
    "absent hint maps to None, still a 429 HttpError"
    (Some None)
    (retry_after_of_outcome (KRA.core_error_to_runtime_outcome (rate_limited None)))

(* [Retry.Timeout] spans Admission, Queue, First_token and Capacity_backpressure
   waits, none of which touched a socket. Routing them to
   [NetworkError { kind = Timeout }] labelled them ETIMEDOUT and dropped the
   phase; [TimeoutError] is the constructor that carries it. A [None] here
   means the outcome was not a [TimeoutError] at all. *)
let timeout_phase_label_of_outcome = function
  | Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.TimeoutError { phase; _ })) ->
    Some (Llm_provider.Http_client.timeout_phase_to_label phase)
  | _ -> None

let api_timeout phase =
  Agent_core.Error.Api
    (Llm_provider.Retry.Timeout { message = "per-provider timeout after 90.0s"; phase })

let test_timeout_threads_phase () =
  Alcotest.(check (option string))
    "an admission-phase timeout stays an admission-phase timeout"
    (Some
       (Llm_provider.Http_client.timeout_phase_to_label
          Llm_provider.Http_client.Admission))
    (timeout_phase_label_of_outcome
       (KRA.core_error_to_runtime_outcome
          (api_timeout (Some Llm_provider.Http_client.Admission))))

let test_timeout_without_phase_is_unknown () =
  Alcotest.(check (option string))
    "an unattributed timeout lands on Unknown_timeout, not a network kind"
    (Some
       (Llm_provider.Http_client.timeout_phase_to_label
          Llm_provider.Http_client.Unknown_timeout))
    (timeout_phase_label_of_outcome (KRA.core_error_to_runtime_outcome (api_timeout None)))

let provider_wire_error () =
  Agent_core.Error.Provider
    (Llm_provider.Error.ProviderWireError
       { provider = "test-provider"
       ; format = Llm_provider.Http_client.Sse
       ; kind = Llm_provider.Http_client.Malformed_payload
       ; detail = "malformed SSE payload"
       })

let provider_reported_error () =
  Agent_core.Error.Provider
    (Llm_provider.Error.ProviderReportedError
       { provider = "test-provider"
       ; error_type = Some "overloaded"
       ; detail = "provider rejected the stream"
       })

let test_provider_wire_failure_is_next_candidate_eligible () =
  match KRA.core_error_to_runtime_outcome (provider_wire_error ()) with
  | Some (Runtime_attempt_fsm.Call_err (Llm_provider.Http_client.ProviderFailure error)) ->
    (match error.kind with
     | Llm_provider.Http_client.Provider_wire_error
         { format = Llm_provider.Http_client.Sse
         ; kind = Llm_provider.Http_client.Malformed_payload
         } ->
       Alcotest.(check bool)
         "typed wire failure tries the next lane candidate"
         true
         (Runtime_attempt_fsm.should_try_next
            (Llm_provider.Http_client.ProviderFailure error))
     | _ -> Alcotest.fail "wire failure kind was not preserved")
  | _ -> Alcotest.fail "wire failure did not map to ProviderFailure"

let test_provider_reported_failure_is_next_candidate_eligible () =
  match KRA.core_error_to_runtime_outcome (provider_reported_error ()) with
  | Some (Runtime_attempt_fsm.Call_err (Llm_provider.Http_client.ProviderFailure error)) ->
    (match error.kind with
     | Llm_provider.Http_client.Provider_reported_error
         { error_type = Some "overloaded" } ->
       Alcotest.(check bool)
         "provider-reported failure tries the next lane candidate"
         true
         (Runtime_attempt_fsm.should_try_next
            (Llm_provider.Http_client.ProviderFailure error))
     | _ -> Alcotest.fail "provider-reported kind was not preserved")
  | _ -> Alcotest.fail "provider-reported failure did not map to ProviderFailure"

let () =
  Alcotest.run
    "keeper_runtime_attempt"
    [ ( "rate_limited_429"
      , [ Alcotest.test_case "threads resolved retry_after" `Quick test_429_threads_resolved_retry_after
        ; Alcotest.test_case "absent hint stays None" `Quick test_429_without_hint_stays_none
        ] )
    ; ( "timeout_phase"
      , [ Alcotest.test_case "phase threads through" `Quick test_timeout_threads_phase
        ; Alcotest.test_case
            "absent phase is Unknown_timeout"
            `Quick
            test_timeout_without_phase_is_unknown
        ] )
    ; ( "provider_failures"
      , [ Alcotest.test_case
            "wire failure tries next candidate"
            `Quick
            test_provider_wire_failure_is_next_candidate_eligible
        ; Alcotest.test_case
            "provider-reported failure tries next candidate"
            `Quick
            test_provider_reported_failure_is_next_candidate_eligible
        ] )
    ]
