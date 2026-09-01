(** Prompt_names — SSOT for Prompt_registry template keys.

    Each key names the reader it addresses, and every key here has exactly one
    asset in config/prompts. *)

val keeper : string
(** The Keeper's standing rules. *)

(** Read-only Tool-plan proposal assembly from exact capability references. *)

val judge_board : string
(** Relevance of one Board signal to one Keeper. *)

val judge_effect : string
(** Approve, deny, or escalate one exact Keeper external effect. *)

val verification : string
(** Task completion review against the submitted evidence snapshot. *)

val goal_verification_proof : string

val goal_verification_lookup : string
(** The read-only surface the Goal proof judge holds, described to it. A
    surface the judge is never told about is a surface it never uses. *)
(** Goal completion proof review (RFC-0387 B3): did the goal's declared
    metric reach its declared target value? *)

val verification_lookup_none : string
val verification_lookup_producer_tree : string
val verification_contract : string
val verification_required_evidence : string
val keeper_observation_recovered_current_task : string
val keeper_observation_current_task_absent : string
val keeper_observation_current_task_absent_in_recovery : string
val keeper_observation_current_task_unobservable : string
val keeper_current_task_skills : string
val keeper_held_task_skills : string
val keeper_held_task_skills_heading : string
val keeper_observation_rejected_digest_heading : string
val keeper_observation_rejected_digest_row : string
(** The instruction attached to the skills named by the current task. *)

(** Goal success-criterion viability review (RFC-0387 B2): is the declared
    metric/target reachable in principle? *)

val librarian : string

val fusion_judge : string
val fusion_judge_refine : string
val fusion_judge_meta : string
val fusion_judge_output : string
val mcp_full : string
val mcp_managed_agent : string
val mcp_operator_remote : string
val keeper_workspace : string
val keeper_identity : string
val keeper_canary_judge_system : string
val keeper_canary_judge_user : string
val keeper_canary_recall : string
val keeper_capability_probe : string
val lane_cli_probe_librarian_system : string
val lane_cli_probe_librarian_user : string
val lane_cli_probe_hitl_system : string
val lane_cli_probe_hitl_user : string
val keeper_antigravity_system_instructions_label : string
val keeper_antigravity_current_goal_label : string
val eval_calibration_few_shot : string
val eval_calibration_few_shot_example : string

(** Repository checkout freshness fragments. *)
val keeper_context_checkouts_section : string
val keeper_context_checkouts_row : string
val keeper_context_checkouts_standing_current : string
val keeper_context_checkouts_standing_ahead : string
val keeper_context_checkouts_standing_behind : string
val keeper_context_checkouts_standing_diverged : string
val keeper_context_checkouts_standing_unavailable : string
val keeper_context_checkouts_unmeasured : string

(** Approval authority fragments. *)
val keeper_context_approval_authority_heading : string
val keeper_context_approval_authority_state_complete : string
val keeper_context_approval_authority_state_partial : string
val keeper_context_approval_authority_state_unavailable : string
val keeper_context_approval_authority_footer : string
(** Current-memory selection. *)
