(** Regression test for the [source] label classifier of
    [masc_keeper_oas_run_timeout_total] (PR #13941).

    The classifier discriminates on a substring of the
    [Llm_provider.Retry.Timeout] message; the substring is the
    literal text agent_sdk emits at
    [agent_sdk/agent/agent.ml:255]:
      "Agent execution exceeded max_execution_time_s (%f)"

    If agent_sdk changes that format, this test fails loudly *before*
    the production metric silently misclassifies every wrapper hit as
    a transport-level timeout. *)

open Masc_mcp

let check_string = Alcotest.(check string)

let timeout_err message =
  Agent_sdk.Error.Api (Llm_provider.Retry.Timeout { message })

let test_max_execution_time_message_classifies () =
  let err =
    timeout_err
      "Agent execution exceeded max_execution_time_s (300.000000)"
  in
  check_string
    "wrapper message → max_execution_time"
    "max_execution_time"
    (Oas_worker_named_fsm.timeout_source_label err)

let test_max_execution_time_substring_anywhere () =
  (* The classifier should be robust to surrounding text — case
     insensitivity is part of [String_util.contains_substring_ci],
     so an upper-cased fragment must still match. *)
  let err =
    timeout_err
      "wrapped: AGENT EXECUTION EXCEEDED MAX_EXECUTION_TIME_S (45.0); cascade fallback engaged"
  in
  check_string
    "uppercase substring still classifies as max_execution_time"
    "max_execution_time"
    (Oas_worker_named_fsm.timeout_source_label err)

let test_provider_timeout_without_substring () =
  (* Generic transport-level timeout — different message, must
     fall through to the [provider] bucket. *)
  let err =
    timeout_err
      "HTTP read deadline exceeded after 30 seconds"
  in
  check_string
    "transport timeout → provider"
    "provider"
    (Oas_worker_named_fsm.timeout_source_label err)

let test_non_timeout_error_classifies_as_provider () =
  (* Non-Timeout errors should not crash the classifier; they
     produce the [provider] bucket so callers can pass any error
     and rely on the no-op for the metric path. *)
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message = "DNS lookup failed"
         ; kind = Llm_provider.Http_client.Dns_failure
         })
  in
  check_string
    "non-Timeout error → provider"
    "provider"
    (Oas_worker_named_fsm.timeout_source_label err)

let test_empty_message_falls_back_to_provider () =
  (* Defensive: agent_sdk should never produce an empty message
     for [Retry.Timeout], but if it did the classifier must not
     mis-attribute it. *)
  let err = timeout_err "" in
  check_string
    "empty message → provider"
    "provider"
    (Oas_worker_named_fsm.timeout_source_label err)

let () =
  Alcotest.run "Oas_run_timeout_source_label"
    [
      ( "classification",
        [
          Alcotest.test_case
            "exact wrapper message"
            `Quick
            test_max_execution_time_message_classifies;
          Alcotest.test_case
            "uppercase substring"
            `Quick
            test_max_execution_time_substring_anywhere;
          Alcotest.test_case
            "transport timeout"
            `Quick
            test_provider_timeout_without_substring;
          Alcotest.test_case
            "non-Timeout error"
            `Quick
            test_non_timeout_error_classifies_as_provider;
          Alcotest.test_case
            "empty message defensive"
            `Quick
            test_empty_message_falls_back_to_provider;
        ] );
    ]
