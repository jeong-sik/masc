(* test/test_keeper_usage_trust_counter.ml

   Usage observation test: verify [record_usage_trust]
   helper increments the right Otel_metric_store counters for each
   [usage_trust] variant and isolates labels across keepers.

   Only objective negative-counter violations are invalid. Zero or large
   provider-reported counts remain observations and are never rejected by a
   local threshold. *)

module UM = Masc.Keeper_unified_metrics
module UT = Keeper_usage_trust
module Metrics = Masc.Otel_metric_store
module KMC = Masc.Keeper_meta_contract

let outcome_for ~keeper ~outcome =
  Metrics.metric_value_or_zero
    UM.usage_trust_outcome_metric
    ~labels:[ ("keeper", keeper); ("outcome", outcome) ]
    ()

let reason_for ~keeper ~reason =
  Metrics.metric_value_or_zero
    UM.usage_anomaly_reason_metric
    ~labels:[ ("keeper", keeper); ("reason", reason) ]
    ()

let test_metric_names_stable () =
  (* Dashboards / Grafana rules pin these exact strings. *)
  Alcotest.(check string)
    "outcome metric canonical"
    "masc_keeper_usage_trust_total"
    UM.usage_trust_outcome_metric;
  Alcotest.(check string)
    "anomaly reason metric canonical"
    "masc_keeper_usage_anomaly_reason_total"
    UM.usage_anomaly_reason_metric

let test_trusted_outcome_only () =
  let keeper = "test-keeper-9959-ok" in
  let before = outcome_for ~keeper ~outcome:"trusted" in
  UM.record_usage_trust ~keeper_name:keeper ~trust:UM.Usage_trusted;
  Alcotest.(check (float 0.0001))
    "trusted outcome +1"
    (before +. 1.0)
    (outcome_for ~keeper ~outcome:"trusted")

let test_missing_outcome_only () =
  (* Ollama-style "no usage reported at all" — honest signal, not an
     anomaly with reasons.  The outcome counter ticks but no
     per-reason counter moves. *)
  let keeper = "test-keeper-9959-missing" in
  let outcome_before = outcome_for ~keeper ~outcome:"missing" in
  let reason_before =
    reason_for ~keeper ~reason:"negative_input_tokens"
  in
  UM.record_usage_trust ~keeper_name:keeper ~trust:UM.Usage_missing;
  Alcotest.(check (float 0.0001))
    "missing outcome +1"
    (outcome_before +. 1.0)
    (outcome_for ~keeper ~outcome:"missing");
  Alcotest.(check (float 0.0001))
    "no reason counter movement for missing"
    reason_before
    (reason_for ~keeper ~reason:"negative_input_tokens")

let test_untrusted_bumps_per_reason () =
  (* Invalid negative counters remain explicit and observable. *)
  let keeper = "test-keeper-9959-untrusted" in
  let outcome_before = outcome_for ~keeper ~outcome:"untrusted" in
  let input_before = reason_for ~keeper ~reason:"negative_input_tokens" in
  let output_before =
    reason_for ~keeper ~reason:"negative_output_tokens"
  in
  UM.record_usage_trust
    ~keeper_name:keeper
    ~trust:
      (UM.Usage_untrusted
         [ "negative_input_tokens"; "negative_output_tokens" ]);
  Alcotest.(check (float 0.0001))
    "untrusted outcome +1"
    (outcome_before +. 1.0)
    (outcome_for ~keeper ~outcome:"untrusted");
  Alcotest.(check (float 0.0001))
    "negative input reason +1"
    (input_before +. 1.0)
    (reason_for ~keeper ~reason:"negative_input_tokens");
  Alcotest.(check (float 0.0001))
    "negative output reason +1"
    (output_before +. 1.0)
    (reason_for ~keeper ~reason:"negative_output_tokens")

let test_per_keeper_isolation () =
  let a = "test-keeper-9959-a" in
  let b = "test-keeper-9959-b" in
  let a_before = outcome_for ~keeper:a ~outcome:"untrusted" in
  let b_before = outcome_for ~keeper:b ~outcome:"untrusted" in
  UM.record_usage_trust ~keeper_name:a
    ~trust:(UM.Usage_untrusted [ "negative_input_tokens" ]);
  Alcotest.(check (float 0.0001))
    "A untrusted +1"
    (a_before +. 1.0)
    (outcome_for ~keeper:a ~outcome:"untrusted");
  Alcotest.(check (float 0.0001))
    "B untrusted unchanged" b_before
    (outcome_for ~keeper:b ~outcome:"untrusted")

let test_zero_and_large_usage_are_reported () =
  let zero = Agent_core.Types.zero_api_usage in
  let large = { zero with input_tokens = 2_000_000; output_tokens = 3_000_000 } in
  Alcotest.(check bool)
    "zero usage is an ordinary report"
    true
    (match UT.classify ~usage_reported:true ~usage:zero with
     | UT.Usage_trusted -> true
     | UT.Usage_missing | UT.Usage_untrusted _ -> false);
  Alcotest.(check bool)
    "large usage is not rejected by a local threshold"
    true
    (match UT.classify ~usage_reported:true ~usage:large with
     | UT.Usage_trusted -> true
     | UT.Usage_missing | UT.Usage_untrusted _ -> false)

let test_negative_usage_warns_operator () =
  Alcotest.(check bool)
    "objective invalid counter warns"
    true
    (UT.warns_operator (UT.Usage_untrusted [ "negative_input_tokens" ]))

let prior_usage : KMC.usage_metrics =
  {
    total_turns = 7;
    total_input_tokens = 700;
    total_output_tokens = 70;
    total_tokens = 770;
    total_cost_usd = 1.25;
    last_turn_ts = 50.0;
    last_input_tokens = 101;
    last_output_tokens = 11;
    last_total_tokens = 112;
    last_usage_reported_at = Some 40.0;
    last_latency_ms = 250;
  }
;;

let test_missing_usage_preserves_last_provider_observation () =
  let actual =
    KMC.with_last_reported_usage prior_usage
      ~usage_reported:false
      ~input_tokens:0
      ~output_tokens:0
      ~total_tokens:0
      ~observed_at:60.0
  in
  Alcotest.(check int)
    "input preserved"
    prior_usage.last_input_tokens
    actual.last_input_tokens;
  Alcotest.(check int)
    "output preserved"
    prior_usage.last_output_tokens
    actual.last_output_tokens;
  Alcotest.(check int)
    "total preserved"
    prior_usage.last_total_tokens
    actual.last_total_tokens;
  Alcotest.(check (option (float 0.0001)))
    "timestamp preserved"
    prior_usage.last_usage_reported_at
    actual.last_usage_reported_at
;;

let test_reported_usage_replaces_whole_provider_observation () =
  let actual =
    KMC.with_last_reported_usage prior_usage
      ~usage_reported:true
      ~input_tokens:202
      ~output_tokens:22
      ~total_tokens:224
      ~observed_at:60.0
  in
  Alcotest.(check int) "input replaced" 202 actual.last_input_tokens;
  Alcotest.(check int) "output replaced" 22 actual.last_output_tokens;
  Alcotest.(check int) "total replaced" 224 actual.last_total_tokens;
  Alcotest.(check (option (float 0.0001)))
    "timestamp replaced"
    (Some 60.0)
    actual.last_usage_reported_at
;;

let () =
  Alcotest.run "keeper_usage_trust_counter_9959"
    [
      ( "metric_names",
        [
          Alcotest.test_case "canonical names stable" `Quick
            test_metric_names_stable;
        ] );
      ( "trust_outcomes",
        [
          Alcotest.test_case "trusted increments outcome only" `Quick
            test_trusted_outcome_only;
          Alcotest.test_case "missing increments outcome only" `Quick
            test_missing_outcome_only;
          Alcotest.test_case "untrusted bumps per-reason" `Quick
            test_untrusted_bumps_per_reason;
        ] );
      ( "isolation",
        [
          Alcotest.test_case "per-keeper independent" `Quick
            test_per_keeper_isolation;
        ] );
      ( "severity",
        [
          Alcotest.test_case "zero and large usage are reported" `Quick
            test_zero_and_large_usage_are_reported;
          Alcotest.test_case "negative usage warns" `Quick
            test_negative_usage_warns_operator;
        ] );
      ( "last_provider_observation",
        [
          Alcotest.test_case "missing usage preserves observation" `Quick
            test_missing_usage_preserves_last_provider_observation;
          Alcotest.test_case "reported usage replaces observation" `Quick
            test_reported_usage_replaces_whole_provider_observation;
        ] );
    ]
