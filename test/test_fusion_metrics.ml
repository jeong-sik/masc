(* RFC-0284 — Fusion deliberation OTel metrics wiring. *)

open Alcotest
open Masc

let sample_usage : Fusion_types.usage =
  { Fusion_types.input_tokens = 100; output_tokens = 50 }

let sample_synthesis : Fusion_types.judge_synthesis =
  { Fusion_types.consensus = []
  ; contradictions = []
  ; partial_coverage = []
  ; unique_insights = []
  ; blind_spots = []
  ; resolved_answer = "ok"
  ; decision = Fusion_types.Answer "ok"
  }

let test_labels () =
  check string "topology simple" "simple"
    (Fusion_metrics.topology_label Fusion_types.Simple);
  check string "topology judge_of_judges" "judge_of_judges"
    (Fusion_metrics.topology_label Fusion_types.Judge_of_judges);
  check string "role single" "single"
    (Fusion_metrics.judge_role_label Fusion_types.Single);
  check string "role first" "first"
    (Fusion_metrics.judge_role_label (Fusion_types.First "p1"));
  check string "role stage_meta" "stage_meta"
    (Fusion_metrics.judge_role_label (Fusion_types.Stage_meta 1));
  check string "role final_meta" "final_meta"
    (Fusion_metrics.judge_role_label Fusion_types.Final_meta);
  check string "outcome synthesized" "synthesized"
    (Fusion_metrics.judge_outcome_label
       (Fusion_types.Synthesized
          { Fusion_types.role = Single; synthesis = sample_synthesis; usage = sample_usage }));
  check string "outcome failed" "failed"
    (Fusion_metrics.judge_outcome_label
       (Fusion_types.Judge_failed
          { Fusion_types.failed_role = Meta
          ; failure = Fusion_types.Provider_error "boom"
          ; usage = sample_usage
          ; elapsed_s = 0.0
          }))

let test_record_judge_execution_emits () =
  let before =
    Otel_metric_store.metric_value_or_zero
      Fusion_metrics.metric_fusion_judge_executions_total
      ~labels:[ "topology", "simple"; "role", "single"; "outcome", "synthesized" ]
      ()
  in
  Fusion_metrics.record_judge_execution
    ~topology:Fusion_types.Simple
    (Fusion_types.Synthesized
       { Fusion_types.role = Single; synthesis = sample_synthesis; usage = sample_usage });
  let after =
    Otel_metric_store.metric_value_or_zero
      Fusion_metrics.metric_fusion_judge_executions_total
      ~labels:[ "topology", "simple"; "role", "single"; "outcome", "synthesized" ]
      ()
  in
  check (float 0.0) "counter incremented by 1.0" (before +. 1.0) after

let test_record_invocation_emits () =
  let before =
    Otel_metric_store.metric_value_or_zero
      Fusion_metrics.metric_fusion_invocations_total
      ~labels:[ "topology", "refine"; "outcome", "completed" ]
      ()
  in
  Fusion_metrics.record_invocation ~topology:Fusion_types.Refine `Completed;
  let after =
    Otel_metric_store.metric_value_or_zero
      Fusion_metrics.metric_fusion_invocations_total
      ~labels:[ "topology", "refine"; "outcome", "completed" ]
      ()
  in
  check (float 0.0) "counter incremented by 1.0" (before +. 1.0) after

let () =
  run "fusion_metrics"
    [ ( "labels"
      , [ test_case "topology/role/outcome labels" `Quick test_labels ] )
    ; ( "emission"
      , [ test_case "record_judge_execution increments counter" `Quick
            test_record_judge_execution_emits
        ; test_case "record_invocation increments counter" `Quick
            test_record_invocation_emits
        ] )
    ]
