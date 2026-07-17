(** Mapping tests for [Keeper_runtime_attempt.sdk_error_to_runtime_outcome].

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
  Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited { message = "slow down"; retry_after })

let test_429_threads_resolved_retry_after () =
  Alcotest.(check (option (option (float 0.0))))
    "resolved retry-after re-enters via the header slot"
    (Some (Some 42.0))
    (retry_after_of_outcome (KRA.sdk_error_to_runtime_outcome (rate_limited (Some 42.0))))

let test_429_without_hint_stays_none () =
  Alcotest.(check (option (option (float 0.0))))
    "absent hint maps to None, still a 429 HttpError"
    (Some None)
    (retry_after_of_outcome (KRA.sdk_error_to_runtime_outcome (rate_limited None)))

let () =
  Alcotest.run
    "keeper_runtime_attempt"
    [ ( "rate_limited_429"
      , [ Alcotest.test_case "threads resolved retry_after" `Quick test_429_threads_resolved_retry_after
        ; Alcotest.test_case "absent hint stays None" `Quick test_429_without_hint_stays_none
        ] )
    ]
