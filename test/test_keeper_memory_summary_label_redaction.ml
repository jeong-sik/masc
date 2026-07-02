(* RFC-0132 PR-2 regression: the keeper memory-summary outcome counter must
   emit the neutral runtime lane in its [provider] label, never the concrete
   model id. Runtime identity is preserved by the separate [runtime_id] label. *)

module Summary = Masc.Keeper_memory_llm_summary
module Metrics = Masc.Otel_metric_store
module Outcome = Keeper_memory_llm_summary_outcome

let metric = Keeper_metrics.(to_string MemoryLlmSummaryOutcomes)
let runtime_lane = Masc.Keeper_hooks_oas.runtime_lane_label
let runtime_id = "test-runtime-memory-summary-label"
let raw_model_id = "vendor/concrete-model-must-not-leak"
let outcome = Outcome.Ok_summary

(* Label order matches the emission order in [record_summary_outcome]. *)
let redacted_labels =
  [ "outcome", Outcome.to_label outcome
  ; "provider", runtime_lane
  ; "runtime_id", runtime_id
  ]

let leaked_labels =
  [ "outcome", Outcome.to_label outcome
  ; "provider", raw_model_id
  ; "runtime_id", runtime_id
  ]

let test_runtime_lane_value_is_neutral () =
  Alcotest.(check string)
    "runtime lane label is the neutral constant"
    "runtime"
    runtime_lane

let test_provider_label_redacted_to_runtime_lane () =
  let before_redacted = Metrics.metric_value_or_zero metric ~labels:redacted_labels () in
  let before_leaked = Metrics.metric_value_or_zero metric ~labels:leaked_labels () in
  Summary.For_testing.record_summary_outcome ~runtime_id ~outcome;
  Alcotest.(check (float 0.0001))
    "provider=runtime labelset increments by 1"
    (before_redacted +. 1.0)
    (Metrics.metric_value_or_zero metric ~labels:redacted_labels ());
  Alcotest.(check (float 0.0001))
    "raw model_id labelset never materializes"
    before_leaked
    (Metrics.metric_value_or_zero metric ~labels:leaked_labels ())

let () =
  Alcotest.run
    "keeper_memory_summary_label_redaction"
    [ ( "otel-label"
      , [ Alcotest.test_case
            "runtime lane value is neutral"
            `Quick
            test_runtime_lane_value_is_neutral
        ; Alcotest.test_case
            "provider label redacted to runtime lane"
            `Quick
            test_provider_label_redacted_to_runtime_lane
        ] )
    ]
