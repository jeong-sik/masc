(* test/test_keeper_usage_trust_counter.ml

   #9959 defensive layer test: verify the new [record_usage_trust]
   helper increments the right Prometheus counters for each
   [usage_trust] variant and isolates labels across keepers.

   The upstream root cause (accumulated values leaking into
   per-response api_usage) is tracked in jeong-sik/oas#1181; the
   counters here surface the anomaly rate so operators can alert
   while that fix is in-flight. *)

module UM = Masc_mcp.Keeper_unified_metrics
module Prom = Masc_mcp.Prometheus

let outcome_for ~keeper ~outcome =
  Prom.metric_value_or_zero
    UM.usage_trust_outcome_metric
    ~labels:[ "keeper", keeper; "outcome", outcome ]
    ()
;;

let reason_for ~keeper ~reason =
  Prom.metric_value_or_zero
    UM.usage_anomaly_reason_metric
    ~labels:[ "keeper", keeper; "reason", reason ]
    ()
;;

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
;;

let test_trusted_outcome_only () =
  let keeper = "test-keeper-9959-ok" in
  let before = outcome_for ~keeper ~outcome:"trusted" in
  UM.record_usage_trust ~keeper_name:keeper ~trust:UM.Usage_trusted;
  Alcotest.(check (float 0.0001))
    "trusted outcome +1"
    (before +. 1.0)
    (outcome_for ~keeper ~outcome:"trusted")
;;

let test_missing_outcome_only () =
  (* Ollama-style "no usage reported at all" — honest signal, not an
     anomaly with reasons.  The outcome counter ticks but no
     per-reason counter moves. *)
  let keeper = "test-keeper-9959-missing" in
  let outcome_before = outcome_for ~keeper ~outcome:"missing" in
  let reason_before = reason_for ~keeper ~reason:"input_tokens_gt_1m" in
  UM.record_usage_trust ~keeper_name:keeper ~trust:UM.Usage_missing;
  Alcotest.(check (float 0.0001))
    "missing outcome +1"
    (outcome_before +. 1.0)
    (outcome_for ~keeper ~outcome:"missing");
  Alcotest.(check (float 0.0001))
    "no reason counter movement for missing"
    reason_before
    (reason_for ~keeper ~reason:"input_tokens_gt_1m")
;;

let test_untrusted_bumps_per_reason () =
  (* The #9959 path: per-response api_usage carries accumulated
     values — [input_tokens_gt_1m] fires together with
     [input_tokens_gt_2x_context_max]. Both reason counters must
     tick alongside the outcome counter. *)
  let keeper = "test-keeper-9959-untrusted" in
  let outcome_before = outcome_for ~keeper ~outcome:"untrusted" in
  let gt1m_before = reason_for ~keeper ~reason:"input_tokens_gt_1m" in
  let gt2x_before = reason_for ~keeper ~reason:"input_tokens_gt_2x_context_max" in
  UM.record_usage_trust
    ~keeper_name:keeper
    ~trust:(UM.Usage_untrusted [ "input_tokens_gt_1m"; "input_tokens_gt_2x_context_max" ]);
  Alcotest.(check (float 0.0001))
    "untrusted outcome +1"
    (outcome_before +. 1.0)
    (outcome_for ~keeper ~outcome:"untrusted");
  Alcotest.(check (float 0.0001))
    "input_tokens_gt_1m reason +1"
    (gt1m_before +. 1.0)
    (reason_for ~keeper ~reason:"input_tokens_gt_1m");
  Alcotest.(check (float 0.0001))
    "input_tokens_gt_2x_context_max reason +1"
    (gt2x_before +. 1.0)
    (reason_for ~keeper ~reason:"input_tokens_gt_2x_context_max")
;;

let test_per_keeper_isolation () =
  let a = "test-keeper-9959-a" in
  let b = "test-keeper-9959-b" in
  let a_before = outcome_for ~keeper:a ~outcome:"untrusted" in
  let b_before = outcome_for ~keeper:b ~outcome:"untrusted" in
  UM.record_usage_trust
    ~keeper_name:a
    ~trust:(UM.Usage_untrusted [ "zero_token_usage_reported" ]);
  Alcotest.(check (float 0.0001))
    "A untrusted +1"
    (a_before +. 1.0)
    (outcome_for ~keeper:a ~outcome:"untrusted");
  Alcotest.(check (float 0.0001))
    "B untrusted unchanged"
    b_before
    (outcome_for ~keeper:b ~outcome:"untrusted")
;;

let () =
  Alcotest.run
    "keeper_usage_trust_counter_9959"
    [ ( "metric_names"
      , [ Alcotest.test_case "canonical names stable" `Quick test_metric_names_stable ] )
    ; ( "trust_outcomes"
      , [ Alcotest.test_case
            "trusted increments outcome only"
            `Quick
            test_trusted_outcome_only
        ; Alcotest.test_case
            "missing increments outcome only"
            `Quick
            test_missing_outcome_only
        ; Alcotest.test_case
            "untrusted bumps per-reason"
            `Quick
            test_untrusted_bumps_per_reason
        ] )
    ; ( "isolation"
      , [ Alcotest.test_case "per-keeper independent" `Quick test_per_keeper_isolation ] )
    ]
;;
