(** Fusion deliberation OTel metrics (RFC-0284). *)

val metric_fusion_invocations_total : string
val metric_fusion_judge_executions_total : string

val topology_label : Fusion_types.fusion_topology -> string
val judge_role_label : Fusion_types.judge_role -> string
val judge_outcome_label : Fusion_types.judge_outcome -> string

val record_judge_execution : topology:Fusion_types.fusion_topology -> Fusion_types.judge_outcome -> unit
(** Emit a counter increment for one executed judge node.
    Labels: [topology],
    [role] \in {single, refine_pass, first, meta, stage_meta, final_meta},
    [outcome] \in {synthesized, failed}. *)

type delivery = Recorded | Sink_failed

val record_denied : topology:Fusion_types.fusion_topology -> unit
(** One policy refusal: outcome=denied, judge_result=not_attempted. *)

val record_projection
  : topology:Fusion_types.fusion_topology
  -> delivery:delivery
  -> Fusion_types.deliberation_evidence
  -> unit
(** Record one returned projection attempt, with independent delivery [outcome]
    (completed/sink_failed) and [judge_result] (synthesized,
    synthesized_with_failures, failed, not_attempted). Read the canonical result
    and actual judge nodes; no elapsed time, usage, or dispatch is inferred.
    Failed panel quorum has no judge nodes and is not a failed judge execution.
    Repeated delivery attempts each increment this process-local counter; it is
    not a distinct-run count or a durable dispatch receipt. Exceptions that do
    not return a sink result are not represented by this counter. *)
