(* RFC-0284 — Fusion deliberation OTel metrics wiring. *)

open Alcotest
open Masc

(* The keeper.world event-row prose this suite asserts (the fusion
   completion titles) moved out of the .ml sources into
   config/prompts/keeper.world.*.md group files, rendered through the prompt
   registry at observation time. This executable never pinned a markdown
   dir, so prompt resolution depended on whatever the host/dune context
   happened to expose — green on developer machines, bare-data fallbacks
   inside the CI dune sandbox. Pin resolution to the repo's own prompt
   files — the same idiom test_tool_task_coverage uses; that executable
   passes inside the CI sandbox, so the mechanism is CI-proven. *)
let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.world.frame.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let () =
  Prompt_registry.set_markdown_dir (Filename.concat (repo_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()
;;

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
  check string "topology staged_judge_of_judges" "staged_judge_of_judges"
    (Fusion_metrics.topology_label Fusion_types.Staged_judge_of_judges);
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
          ; elapsed_s = None
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
