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

val record_invocation : topology:Fusion_types.fusion_topology -> [< `Denied | `Sink_failed | `Completed ] -> unit
(** Emit a counter increment for one fusion invocation.
    Labels: [topology], [outcome] \in {denied, sink_failed, completed}. *)
