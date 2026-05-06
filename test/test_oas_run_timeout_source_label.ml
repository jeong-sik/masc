(** Regression test for the [source] label classifier of
    [masc_keeper_oas_run_timeout_total] (PR #13941).

    The classifier discriminates on the prefix of the
    [Llm_provider.Retry.Timeout] message; the prefix is the literal
    text agent_sdk emits at
    [agent_sdk/agent/agent.ml:255]:
      "Agent execution exceeded max_execution_time_s (%f)"

    If agent_sdk changes that format, this test fails loudly *before*
    the production metric silently misclassifies wrapper hits as
    transport-level timeouts or provider messages as wrapper hits. *)

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

let test_max_execution_time_prefix_is_case_insensitive () =
  (* The classifier should be case-insensitive but still require the
     agent_sdk wrapper prefix, so provider messages that merely mention
     max_execution_time_s do not get attributed to the wrapper. *)
  let err =
    timeout_err
      "AGENT EXECUTION EXCEEDED MAX_EXECUTION_TIME_S (45.0); cascade fallback engaged"
  in
  check_string
    "uppercase prefix still classifies as max_execution_time"
    "max_execution_time"
    (Oas_worker_named_fsm.timeout_source_label err)

let test_provider_timeout_with_substring_falls_back_to_provider () =
  (* A provider/transport timeout can include the same knob name in its
     diagnostic text. That must remain a provider timeout unless the
     message starts with agent_sdk's wrapper prefix. *)
  let err =
    timeout_err
      "Provider Ollama rejected max_execution_time_s during request setup"
  in
  check_string
    "provider message mentioning max_execution_time_s → provider"
    "provider"
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

(* ----------------------------------------------------------------
   Side-effect tests for [emit_sdk_provider_error_metric]
   ---------------------------------------------------------------- *)

let oas_run_timeout_count ~cascade ~provider ~source =
  Prometheus.metric_value_or_zero
    Prometheus.metric_keeper_oas_run_timeout
    ~labels:
      [ ("cascade", cascade)
      ; ("provider", provider)
      ; ("source", source)
      ]
    ()

let cascade_name_for_test name =
  Oas_worker_named_error.cascade_name_of_string name

let test_emit_increments_max_execution_time_counter () =
  (* Calling [emit_sdk_provider_error_metric] with a wrapper-message
     [Retry.Timeout] must increment the counter under the
     [source="max_execution_time"] label. The function returns
     [None] for [Timeout] (since the cascade FSM does not map it to
     a [Provider_error.t] without [capacity_exhausted]) — the
     side-effect on the new counter is the meaningful observable. *)
  let cascade = "test-cascade-met" in
  let provider = "test-provider-met" in
  let source = "max_execution_time" in
  let before = oas_run_timeout_count ~cascade ~provider ~source in
  let err =
    timeout_err
      "Agent execution exceeded max_execution_time_s (300.000000)"
  in
  let _ =
    Oas_worker_named_fsm.emit_sdk_provider_error_metric
      ~cascade_name:(cascade_name_for_test cascade) ~provider err
  in
  let after = oas_run_timeout_count ~cascade ~provider ~source in
  Alcotest.(check (float 0.0001))
    "max_execution_time counter incremented by 1"
    1.0 (after -. before)

let test_emit_increments_provider_counter_on_transport_timeout () =
  let cascade = "test-cascade-prov" in
  let provider = "test-provider-prov" in
  let source = "provider" in
  let before = oas_run_timeout_count ~cascade ~provider ~source in
  let err = timeout_err "HTTP read deadline exceeded" in
  let _ =
    Oas_worker_named_fsm.emit_sdk_provider_error_metric
      ~cascade_name:(cascade_name_for_test cascade) ~provider err
  in
  let after = oas_run_timeout_count ~cascade ~provider ~source in
  Alcotest.(check (float 0.0001))
    "provider-source counter incremented by 1"
    1.0 (after -. before)

let test_emit_does_not_touch_counter_on_non_timeout () =
  let cascade = "test-cascade-nontmo" in
  let provider = "test-provider-nontmo" in
  let before_max =
    oas_run_timeout_count ~cascade ~provider ~source:"max_execution_time"
  in
  let before_prov =
    oas_run_timeout_count ~cascade ~provider ~source:"provider"
  in
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message = "DNS lookup failed"
         ; kind = Llm_provider.Http_client.Dns_failure
         })
  in
  let _ =
    Oas_worker_named_fsm.emit_sdk_provider_error_metric
      ~cascade_name:(cascade_name_for_test cascade) ~provider err
  in
  let after_max =
    oas_run_timeout_count ~cascade ~provider ~source:"max_execution_time"
  in
  let after_prov =
    oas_run_timeout_count ~cascade ~provider ~source:"provider"
  in
  Alcotest.(check (float 0.0001))
    "no max_execution_time bump on NetworkError"
    0.0 (after_max -. before_max);
  Alcotest.(check (float 0.0001))
    "no provider-source bump on NetworkError"
    0.0 (after_prov -. before_prov)

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
            "uppercase prefix"
            `Quick
            test_max_execution_time_prefix_is_case_insensitive;
          Alcotest.test_case
            "provider substring false positive"
            `Quick
            test_provider_timeout_with_substring_falls_back_to_provider;
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
      ( "side_effect",
        [
          Alcotest.test_case
            "max_execution_time increments counter"
            `Quick
            test_emit_increments_max_execution_time_counter;
          Alcotest.test_case
            "transport timeout increments provider counter"
            `Quick
            test_emit_increments_provider_counter_on_transport_timeout;
          Alcotest.test_case
            "NetworkError leaves counter untouched"
            `Quick
            test_emit_does_not_touch_counter_on_non_timeout;
        ] );
    ]
