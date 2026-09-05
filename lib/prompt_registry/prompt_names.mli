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
val verification_lookup_root_layout_empty : string
(** The line a readable-but-empty lookup root produces in the root layout. *)
val verification_contract : string
val verification_required_evidence : string
val verification_evidence_posture_note_only : string
(** Rendered into a completion question whose fixed snapshot holds zero
    artifacts the judge can open — every item a note or an unusable
    reference. The clause that keeps note-only silence from reading as
    assent (task-785, RFC-0417 §4.3). *)
val verification_evidence_posture_usable : string
(** Rendered into a completion question whose snapshot holds [n] readable,
    untruncated artifacts. Variable: [usable_artifact_count]. *)
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

val keeper_skills_unavailable_diagnostic : string
(** The diagnostic on an [unavailable] Skill catalog row. One sentence, two
    render sites (current task and other held tasks). *)
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

(** MCP [tool_help] prompt body pieces, rendered at [prompts/get] time.
    One slot per assembly piece in [config/prompts/mcp.tool_help.md];
    variables per slot: [focus_row] — [focus]; [tool_section] — [name],
    [short_description], [when_to_use]; [constraint_row] / [doc_ref_row] —
    [item]; [details_section] — [details_markdown]. *)

val mcp_tool_help_intro : string
val mcp_tool_help_focus_row : string
val mcp_tool_help_tool_section : string
val mcp_tool_help_constraint_row : string
val mcp_tool_help_details_section : string
val mcp_tool_help_docs_heading : string
val mcp_tool_help_doc_ref_row : string
val keeper_workspace : string
val keeper_identity : string

val keeper_instructions_custom : string
(** The operator-instructions block. Variable: [instructions]. *)

val keeper_tags_system_open : string
val keeper_tags_system_close : string
val keeper_tags_instructions_open : string
val keeper_tags_instructions_close : string
(** The structural tags wrapping the shared prefix and the instructions. *)

val keeper_capability_probe : string
val lane_cli_probe_librarian_system : string
val lane_cli_probe_librarian_user : string
val lane_cli_probe_hitl_system : string
val lane_cli_probe_hitl_user : string
val keeper_antigravity_system_instructions_label : string
val keeper_antigravity_current_goal_label : string
val eval_calibration_few_shot : string
val eval_calibration_few_shot_example : string

val eval_calibration_few_shot_rejected_label : string
(** The label a divergence example carries when the human rejected what the
    evaluator approved. *)

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

val keeper_world_transcript_header : string
val keeper_world_transcript_intro : string
(** Durable direct-conversation transcript block, prepended to the quoted
    recent-conversation rows in the turn context. *)

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

(** Gate replay delivery wording — one key per replay evidence state and one
    per resolution path, following the keeper.observation.* precedent. The
    model-facing instruction lives in the template; the execution path only
    picks the key and supplies the evidence data. *)

val keeper_gate_replay_evidence_applied : string
val keeper_gate_replay_evidence_applied_with_warning : string
val keeper_gate_replay_evidence_failed : string
val keeper_gate_replay_evidence_indeterminate : string
val keeper_gate_replay_repair_required : string
val keeper_gate_replay_resolution_without_replay_outcome : string
val keeper_gate_replay_resolution_exact_input : string

(** HITL context-summary canonical output contract — the schema is data the
    caller supplies; the contract sentence lives in the template. Variable:
    [schema_json]. *)

val judge_effect_output_contract : string

(** {1 Tool help — shared fallback prose and markdown scaffold}

    Per-tool authored help lives in [config/tools/<name>.toml] [help]; these
    keys are the wording the derivation path renders for a tool without
    [help], plus the section scaffold every help entry's markdown shares. *)

val tool_help_prompt_hint_tool_help : string
val tool_help_when_to_use_tool_help : string
val tool_help_when_to_use_generic : string
val tool_help_constraint_hidden : string
val tool_help_constraint_placeholder : string
val tool_help_constraint_simulation : string
val tool_help_constraint_adapter : string
val tool_help_short_description_empty : string

val tool_help_entry_header : string
(** Variables: [name], [short_description], [visibility], [lifecycle]. *)

val tool_help_entry_when_to_use : string
val tool_help_entry_key_constraints : string
val tool_help_entry_details : string
val tool_help_entry_docs : string
val tool_help_entry_prompt_hints : string
val tool_help_entry_examples : string
val tool_help_entry_alternatives : string
val tool_help_index_header : string

(** {1 Tool-result guidance keys}

    RFC prompts-and-tool-definitions-outside-ocaml §3.11: each closed variant
    arm maps to exactly one key; the prose lives in the group file and the
    execution path only picks the variant and supplies the data. *)

(** keeper.tool_filesystem.* — Keeper filesystem tool-result wording
    ([keeper_tool_filesystem_runtime.fs_guidance]). *)

val keeper_tool_filesystem_offset_not_1_based : string
val keeper_tool_filesystem_limit_not_positive : string
val keeper_tool_filesystem_available_cwds_partial : string
val keeper_tool_filesystem_checkout_scan_failed : string
val keeper_tool_filesystem_cwd_not_directory : string
val keeper_tool_filesystem_offset_beyond_window : string
val keeper_tool_filesystem_offset_beyond_scan_budget : string
val keeper_tool_filesystem_capability_unavailable : string
val keeper_tool_filesystem_publication_failed : string
val keeper_tool_filesystem_directory_publication_failed : string
val keeper_tool_filesystem_append_capability_failed : string
val keeper_tool_filesystem_append_incomplete : string
val keeper_tool_filesystem_recovery_lane_committed : string
val keeper_tool_filesystem_recovery_lane_effect_observed : string
val keeper_tool_filesystem_recovery_lane_not_executed : string
val keeper_tool_filesystem_recovery_lane_indeterminate : string
val keeper_tool_filesystem_recovery_lane_cleanup_detail : string
val keeper_tool_filesystem_gate_record_unavailable : string
val keeper_tool_filesystem_path_required : string
val keeper_tool_filesystem_patch_requires_old_string : string
val keeper_tool_filesystem_patch_target_missing : string

(** keeper.gate_replay.* — one slot per replay resolution state / artifact
    integrity failure; composed per state arm, never one shared template. *)

val keeper_gate_replay_resolution_consumed_without_outcome : string
val keeper_gate_replay_resolution_invalid_replay_state : string
val keeper_gate_replay_resolution_journal_unreadable : string
val keeper_gate_replay_resolution_absent : string
val keeper_gate_replay_resolution_rejected : string
val keeper_gate_replay_artifact_missing : string
val keeper_gate_replay_artifact_length_mismatch : string
val keeper_gate_replay_approval_input_drifted : string
val keeper_gate_replay_approval_consumption_mismatch : string
val keeper_gate_replay_replay_outcome_missing_after_restart : string
val keeper_gate_replay_replay_outcome_before_consumption : string
val keeper_gate_replay_replay_effect_raised : string

(** exec_policy.* — the short block reasons surfaced via
    [Exec_policy.block_reason_to_string] and the cwd sibling-dirs hint. *)

val exec_policy_block_reason_empty_command : string
val exec_policy_block_reason_process_substitution : string
val exec_policy_block_reason_pipes_not_allowed : string
val exec_policy_cwd_existing_siblings_hint : string

(** subset_rewrite.* — the advice templates [Subset_rewrite.to_string]
    renders around the caller-supplied [because]. *)

val subset_rewrite_move_to_field : string
val subset_rewrite_call_this_instead : string
val subset_rewrite_spell_it_as : string

(** tool_guidance.* — generic cross-domain tool-result guidance, one arm of
    [Tool_guidance.t] per key. *)

val tool_guidance_broadcast_delivery_rejected : string
val tool_guidance_broadcast_content_required : string
val tool_guidance_workspace_message_delivery_rejected : string
val tool_guidance_post_execution_hook_failed : string
val tool_guidance_mcp_outcome_unknown : string
val tool_guidance_reject_verdict_requires_reason : string
val tool_guidance_no_metrics_found_for_agent : string
val tool_guidance_invalid_agent_card_action : string

(** agent_core.* — templates the host installs into
    [Agent_core.Tool_guidance_text] at prompt-init time; agent_core itself
    stays config-free. *)

val agent_core_unknown_tool_not_found : string
val agent_core_unknown_tool_not_found_no_tools : string
val agent_core_unknown_tool_closest_registered : string
val agent_core_unknown_tool_extra_characters : string
val agent_core_unknown_tool_not_bare_with_closest : string
val agent_core_unknown_tool_not_bare : string
val agent_core_handoff_description : string
val agent_core_handoff_prompt_param_description : string
val agent_core_agent_tool_prompt_param_description : string
