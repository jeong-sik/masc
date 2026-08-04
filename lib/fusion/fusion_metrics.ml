(** Fusion deliberation OTel metrics (RFC-0284).

    Observation records produced by the orchestrator are mirrored as counters
    so operators can distinguish "no fusion traffic" from "fusion traffic that
    is not wired to telemetry". *)

open Fusion_types

let metric_fusion_invocations_total =
  Otel_metric_store_core.declare_counter "masc_fusion_invocations_total"

let metric_fusion_judge_executions_total =
  Otel_metric_store_core.declare_counter "masc_fusion_judge_executions_total"

(* OTel label vocabulary is the wire vocabulary declared by the topology's
   own module, so the label cannot drift from the parse/serialize pair
   ([fusion_topology_of_string] / [all_fusion_topology_strings]). *)
let topology_label = Fusion_types.fusion_topology_to_string

let judge_role_of_outcome = function
  | Synthesized node -> node.role
  | Judge_failed node -> node.failed_role

let judge_role_label = function
  | Single -> "single"
  | Refine_pass -> "refine_pass"
  | First _ -> "first"
  | Meta -> "meta"
  | Stage_meta _ -> "stage_meta"
  | Final_meta -> "final_meta"

let judge_outcome_label = function
  | Synthesized _ -> "synthesized"
  | Judge_failed _ -> "failed"

let record_judge_execution ~topology node =
  Otel_metric_store_core.inc_counter
    metric_fusion_judge_executions_total
    ~labels:
      [ "topology", topology_label topology
      ; "role", judge_role_label (judge_role_of_outcome node)
      ; "outcome", judge_outcome_label node
      ]
    ()

let record_invocation ~topology outcome =
  let outcome_label =
    match outcome with
    | `Denied -> "denied"
    | `Sink_failed -> "sink_failed"
    | `Completed -> "completed"
  in
  Otel_metric_store_core.inc_counter
    metric_fusion_invocations_total
    ~labels:[ "topology", topology_label topology; "outcome", outcome_label ]
    ()
