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

val keeper_observation_previous_turn_stop_repeated_tool_call : string
(** Rendered into the next turn's Autonomous Trigger layer when the runtime's
    repeated-call guard ended the previous turn. Variables: [tool_name],
    [repeated_count]. *)

val keeper_observation_previous_turn_stop_repeated_assistant_text : string
(** The same for the repeated-assistant-text guard. Variable: [repeated_count]. *)

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

(** {1 keeper.world.* — unified turn frame section prose}

    One group file per section under [config/prompts/keeper.world.<group>.md];
    each [### marker] slot registers as [keeper.world.<group>.<marker>]. The
    bare [keeper.world] key is a historical dashboard name only, never a
    prompt key. *)

val keeper_world_frame_frame : string
val keeper_world_active_goals_heading : string
val keeper_world_active_goals_row : string
val keeper_world_active_goals_row_untitled : string
val keeper_world_active_goals_verifying_annotation : string
val keeper_world_current_task_heading_held : string
val keeper_world_current_task_heading_submitted : string
val keeper_world_current_task_heading_recovery : string
val keeper_world_current_task_status_claimed : string
val keeper_world_current_task_status_in_progress : string
val keeper_world_current_task_status_awaiting_verification : string
val keeper_world_current_task_status_todo : string
val keeper_world_current_task_status_done : string
val keeper_world_current_task_status_cancelled : string
val keeper_world_current_task_row : string
val keeper_world_current_task_handoff : string
val keeper_world_current_task_handoff_next_step : string
val keeper_world_current_task_handoff_evidence : string
val keeper_world_current_task_attribution_full : string
val keeper_world_current_task_attribution_who : string
val keeper_world_current_task_attribution_at : string
val keeper_world_current_task_attribution_none : string
val keeper_world_connected_surfaces_heading : string
val keeper_world_connected_surfaces_state_alive : string
val keeper_world_connected_surfaces_state_offline : string
val keeper_world_connected_surfaces_failure : string
val keeper_world_namespace_state_heading : string
val keeper_world_namespace_state_backlog_unreadable : string
val keeper_world_namespace_state_backlog_empty : string
val keeper_world_namespace_state_backlog_revision : string
val keeper_world_namespace_state_unclaimed : string
val keeper_world_namespace_state_claimable : string
val keeper_world_namespace_state_claimable_more : string
val keeper_world_namespace_state_unclaimed_not_offered : string
val keeper_world_namespace_state_failed : string
val keeper_world_namespace_state_running_fibers : string
val keeper_world_autonomous_trigger_heading : string
val keeper_world_autonomous_trigger_scheduler_scheduled : string
val keeper_world_autonomous_trigger_scheduler_reactive : string
val keeper_world_autonomous_trigger_reasons : string
val keeper_world_autonomous_trigger_since_last : string
val keeper_world_scheduled_automation_heading : string
val keeper_world_scheduled_automation_counts : string
val keeper_world_scheduled_automation_next_due : string
val keeper_world_scheduled_automation_attention_heading : string
val keeper_world_scheduled_automation_attention_note : string
val keeper_world_scheduled_wake_heading_single : string
val keeper_world_scheduled_wake_heading_multi : string
val keeper_world_scheduled_wake_intro : string
val keeper_world_completion_authority_heading : string
val keeper_world_completion_authority_intro : string
val keeper_world_task_cancellations_heading : string
val keeper_world_task_cancellations_intro : string
val keeper_world_own_recent_actions_heading : string
val keeper_world_own_recent_actions_intro : string
val keeper_world_own_recent_actions_turn_ok_row : string
val keeper_world_own_recent_actions_turn_rejected_row : string
val keeper_world_own_recent_actions_turn_rejected_detail_row : string
val keeper_world_pending_messages_heading : string
val keeper_world_pending_messages_intro : string
val keeper_world_pending_messages_mention_row : string
val keeper_world_pending_messages_scope_row : string
val keeper_world_own_board_posts_heading : string
val keeper_world_own_board_posts_intro : string
val keeper_world_board_activity_heading : string
val keeper_world_board_activity_intro : string
val keeper_world_fleet_messages_heading : string
val keeper_world_fleet_messages_intro : string
val keeper_world_fleet_messages_row : string

(** Event-row titles and previews, rendered at observation-creation time. *)

val keeper_world_event_rows_fusion_title_succeeded : string
val keeper_world_event_rows_fusion_title_failed : string
val keeper_world_event_rows_fusion_title_cancelled : string
val keeper_world_event_rows_fusion_cancelled_preview : string
val keeper_world_event_rows_scheduled_wake_title : string
val keeper_world_event_rows_external_attention_title : string
val keeper_world_event_rows_ask_title : string
val keeper_world_event_rows_ask_skipped : string
val keeper_world_event_rows_completion_authority_title : string
val keeper_world_event_rows_completion_authority_preview : string
val keeper_world_event_rows_task_cancelled_title : string
val keeper_world_event_rows_task_cancelled_preview : string
val keeper_world_event_rows_task_cancelled_no_reason : string

(** {1 Tool failure — what the model does next}

    One line per {!Tool_result.tool_failure_class}, appended by [Tool_bridge]
    to every failed tool result the model reads. The class is typed at the
    producer; only the sentence lives here, so the model never has to infer
    the class from the failure message. *)

val tool_failure_dependency_unavailable : string
val tool_failure_policy_rejection : string
val tool_failure_runtime_failure : string
val tool_failure_workflow_rejection : string
val tool_failure_operator_cancelled : string
