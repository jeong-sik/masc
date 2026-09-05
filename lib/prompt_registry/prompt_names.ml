(** Prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let keeper = "keeper"
let judge_board = "judge.board"
let judge_effect = "judge.effect"
let verification = "verification"
let goal_verification_proof = "goal_verification.proof"
let goal_verification_lookup = "goal_verification.lookup"

(* Review sections rendered as their own templates and injected into the review
   prompt. They live as files so the prose is editable and overridable through
   the operator layer, and so a code change cannot leave the instructions
   stale: [Anti_rationalization] supplies the data and picks the key, and holds
   no review prose of its own. *)
let verification_lookup_none = "verification.lookup.none"
let verification_lookup_none_cancellation = "verification.lookup.none.cancellation"
let verification_lookup_producer_tree = "verification.lookup.producer_tree"

let verification_lookup_producer_tree_cancellation =
  "verification.lookup.producer_tree.cancellation"
;;
let verification_lookup_root_layout_empty = "verification.lookup.root_layout_empty"
let verification_cancellation = "verification.cancellation"

let verification_cancellation_contract_context =
  "verification.cancellation.contract_context"
;;

let verification_contract = "verification.contract"
let verification_required_evidence = "verification.required_evidence"

let verification_evidence_posture_note_only =
  "verification.evidence_posture.note_only"
;;

let verification_evidence_posture_usable =
  "verification.evidence_posture.usable"
;;

(* One key per typed degraded-observation state. Each names what the Keeper may
   and may not conclude from that state, which is prose about a data condition
   and belongs beside the other prompt text rather than inside the projection
   that detects it. *)
let keeper_observation_recovered_current_task =
  "keeper.observation.recovered_current_task"
;;

let keeper_observation_current_task_absent = "keeper.observation.current_task_absent"

let keeper_observation_current_task_absent_in_recovery =
  "keeper.observation.current_task_absent_in_recovery"
;;

let keeper_observation_current_task_unobservable =
  "keeper.observation.current_task_unobservable"
;;

let keeper_observation_previous_turn_stop_repeated_tool_call =
  "keeper.observation.previous_turn_stop.repeated_tool_call"
;;

let keeper_observation_previous_turn_stop_repeated_assistant_text =
  "keeper.observation.previous_turn_stop.repeated_assistant_text"
;;

let keeper_observation_rejected_digest_heading =
  "keeper.observation.rejected_digest_heading"
;;

let keeper_observation_rejected_digest_row = "keeper.observation.rejected_digest_row"
let keeper_current_task_skills = "keeper.current_task.skills"
let keeper_held_task_skills = "keeper.held_task.skills"
let keeper_held_task_skills_heading = "keeper.held_task.skills_heading"

(* One sentence, two render sites (current task and other held tasks): the
   diagnostic attached to an [unavailable] Skill catalog row when the exact
   executable projection cannot be produced. *)
let keeper_skills_unavailable_diagnostic = "keeper.skills.unavailable_diagnostic"
let librarian = "librarian"

(* Runtime-owned instruction assets.  A caller may supply data to these
   templates, but the instruction wording itself never lives beside the
   execution path. *)
let fusion_judge = "fusion.judge"
let fusion_judge_refine = "fusion.judge.refine"
let fusion_judge_meta = "fusion.judge.meta"
let fusion_judge_output = "fusion.judge.output"
let mcp_full = "mcp.full"
let mcp_managed_agent = "mcp.managed_agent"
let mcp_operator_remote = "mcp.operator_remote"

(* MCP tool_help prompt body — one slot per assembly piece in
   config/prompts/mcp.tool_help.md, rendered by Mcp_prompt_surface when a
   client calls prompts/get. *)
let mcp_tool_help_intro = "mcp.tool_help.intro"
let mcp_tool_help_focus_row = "mcp.tool_help.focus_row"
let mcp_tool_help_tool_section = "mcp.tool_help.tool_section"
let mcp_tool_help_constraint_row = "mcp.tool_help.constraint_row"
let mcp_tool_help_details_section = "mcp.tool_help.details_section"
let mcp_tool_help_docs_heading = "mcp.tool_help.docs_heading"
let mcp_tool_help_doc_ref_row = "mcp.tool_help.doc_ref_row"
let keeper_workspace = "keeper.workspace"
let keeper_identity = "keeper.identity"

(* System-prompt assembly pieces: the operator-instructions block and the
   structural tags that wrap the shared prefix and the instructions. *)
let keeper_instructions_custom = "keeper.instructions.custom"
let keeper_tags_system_open = "keeper.tags.system_open"
let keeper_tags_system_close = "keeper.tags.system_close"
let keeper_tags_instructions_open = "keeper.tags.instructions_open"
let keeper_tags_instructions_close = "keeper.tags.instructions_close"
let keeper_capability_probe = "keeper.capability_probe"
let lane_cli_probe_librarian_system = "lane_cli_probe.librarian.system"
let lane_cli_probe_librarian_user = "lane_cli_probe.librarian.user"
let lane_cli_probe_hitl_system = "lane_cli_probe.hitl.system"
let lane_cli_probe_hitl_user = "lane_cli_probe.hitl.user"
let keeper_antigravity_system_instructions_label = "keeper.antigravity.system_instructions_label"
let keeper_antigravity_current_goal_label = "keeper.antigravity.current_goal_label"
let eval_calibration_few_shot = "eval.calibration.few_shot"
let eval_calibration_few_shot_example = "eval.calibration.few_shot.example"

(* The label a divergence example carries when the human rejected what the
   evaluator approved. *)
let eval_calibration_few_shot_rejected_label = "eval.calibration.few_shot.rejected_label"

(* Repository checkout freshness — one fragment per line part, so an
   operator can reword any of them without an OCaml change. *)
let keeper_context_checkouts_section = "keeper.context.checkouts.section"
let keeper_context_checkouts_row = "keeper.context.checkouts.row"
let keeper_context_checkouts_standing_current = "keeper.context.checkouts.standing.current"
let keeper_context_checkouts_standing_ahead = "keeper.context.checkouts.standing.ahead"
let keeper_context_checkouts_standing_behind = "keeper.context.checkouts.standing.behind"
let keeper_context_checkouts_standing_diverged = "keeper.context.checkouts.standing.diverged"
let keeper_context_checkouts_standing_unavailable = "keeper.context.checkouts.standing.unavailable"
let keeper_context_checkouts_unmeasured = "keeper.context.checkouts.unmeasured"

(* Approval authority — the same split, so the state wording is an
   operator surface rather than an OCaml literal. *)
let keeper_context_approval_authority_heading = "keeper.context.approval_authority.heading"
let keeper_context_approval_authority_state_complete = "keeper.context.approval_authority.state.complete"
let keeper_context_approval_authority_state_partial = "keeper.context.approval_authority.state.partial"
let keeper_context_approval_authority_state_unavailable = "keeper.context.approval_authority.state.unavailable"
let keeper_context_approval_authority_footer = "keeper.context.approval_authority.footer"

(* keeper.world.* — the unified turn frame's section prose. One group file per
   Keeper_context_layers section (plus the frame preamble and the observation
   event rows); each [### marker] slot in config/prompts/keeper.world.<group>.md
   registers as keeper.world.<group>.<marker>. The bare [keeper.world] key is a
   historical dashboard name only — never a prompt key. *)
let keeper_world_frame_frame = "keeper.world.frame.frame"

(* Durable direct-conversation transcript block, prepended to the quoted
   recent-conversation rows in the turn context. *)
let keeper_world_transcript_header = "keeper.world.transcript.header"
let keeper_world_transcript_intro = "keeper.world.transcript.intro"
let keeper_world_active_goals_heading = "keeper.world.active_goals.heading"
let keeper_world_active_goals_row = "keeper.world.active_goals.row"
let keeper_world_active_goals_row_untitled = "keeper.world.active_goals.row_untitled"

let keeper_world_active_goals_verifying_annotation =
  "keeper.world.active_goals.verifying_annotation"
;;

let keeper_world_current_task_heading_held = "keeper.world.current_task.heading.held"

let keeper_world_current_task_heading_submitted =
  "keeper.world.current_task.heading.submitted"
;;

let keeper_world_current_task_heading_recovery =
  "keeper.world.current_task.heading.recovery"
;;

let keeper_world_current_task_status_claimed = "keeper.world.current_task.status.claimed"

let keeper_world_current_task_status_in_progress =
  "keeper.world.current_task.status.in_progress"
;;

let keeper_world_current_task_status_awaiting_verification =
  "keeper.world.current_task.status.awaiting_verification"
;;

let keeper_world_current_task_status_todo = "keeper.world.current_task.status.todo"
let keeper_world_current_task_status_done = "keeper.world.current_task.status.done"

let keeper_world_current_task_status_cancelled =
  "keeper.world.current_task.status.cancelled"
;;

let keeper_world_current_task_row = "keeper.world.current_task.row"
let keeper_world_current_task_handoff = "keeper.world.current_task.handoff"

let keeper_world_current_task_handoff_next_step =
  "keeper.world.current_task.handoff_next_step"
;;

let keeper_world_current_task_handoff_evidence =
  "keeper.world.current_task.handoff_evidence"
;;

let keeper_world_current_task_attribution_full =
  "keeper.world.current_task.attribution.full"
;;

let keeper_world_current_task_attribution_who =
  "keeper.world.current_task.attribution.who"
;;

let keeper_world_current_task_attribution_at = "keeper.world.current_task.attribution.at"

let keeper_world_current_task_attribution_none =
  "keeper.world.current_task.attribution.none"
;;

let keeper_world_connected_surfaces_heading = "keeper.world.connected_surfaces.heading"

let keeper_world_connected_surfaces_state_alive =
  "keeper.world.connected_surfaces.state.alive"
;;

let keeper_world_connected_surfaces_state_offline =
  "keeper.world.connected_surfaces.state.offline"
;;

let keeper_world_connected_surfaces_failure = "keeper.world.connected_surfaces.failure"
let keeper_world_namespace_state_heading = "keeper.world.namespace_state.heading"

let keeper_world_namespace_state_backlog_unreadable =
  "keeper.world.namespace_state.backlog_unreadable"
;;

let keeper_world_namespace_state_backlog_empty =
  "keeper.world.namespace_state.backlog_empty"
;;

let keeper_world_namespace_state_backlog_revision =
  "keeper.world.namespace_state.backlog_revision"
;;

let keeper_world_namespace_state_unclaimed = "keeper.world.namespace_state.unclaimed"
let keeper_world_namespace_state_claimable = "keeper.world.namespace_state.claimable"

let keeper_world_namespace_state_claimable_more =
  "keeper.world.namespace_state.claimable_more"
;;

let keeper_world_namespace_state_unclaimed_not_offered =
  "keeper.world.namespace_state.unclaimed_not_offered"
;;

let keeper_world_namespace_state_failed = "keeper.world.namespace_state.failed"

let keeper_world_namespace_state_running_fibers =
  "keeper.world.namespace_state.running_fibers"
;;

let keeper_world_autonomous_trigger_heading = "keeper.world.autonomous_trigger.heading"

let keeper_world_autonomous_trigger_scheduler_scheduled =
  "keeper.world.autonomous_trigger.scheduler_scheduled"
;;

let keeper_world_autonomous_trigger_scheduler_reactive =
  "keeper.world.autonomous_trigger.scheduler_reactive"
;;

let keeper_world_autonomous_trigger_reasons = "keeper.world.autonomous_trigger.reasons"

let keeper_world_autonomous_trigger_since_last =
  "keeper.world.autonomous_trigger.since_last"
;;

let keeper_world_scheduled_automation_heading =
  "keeper.world.scheduled_automation.heading"
;;

let keeper_world_scheduled_automation_counts = "keeper.world.scheduled_automation.counts"

let keeper_world_scheduled_automation_next_due =
  "keeper.world.scheduled_automation.next_due"
;;

let keeper_world_scheduled_automation_attention_heading =
  "keeper.world.scheduled_automation.attention_heading"
;;

let keeper_world_scheduled_automation_attention_note =
  "keeper.world.scheduled_automation.attention_note"
;;

let keeper_world_scheduled_wake_heading_single =
  "keeper.world.scheduled_wake.heading_single"
;;

let keeper_world_scheduled_wake_heading_multi =
  "keeper.world.scheduled_wake.heading_multi"
;;

let keeper_world_scheduled_wake_intro = "keeper.world.scheduled_wake.intro"

let keeper_world_completion_authority_heading =
  "keeper.world.completion_authority.heading"
;;

let keeper_world_completion_authority_intro = "keeper.world.completion_authority.intro"
let keeper_world_task_cancellations_heading = "keeper.world.task_cancellations.heading"
let keeper_world_task_cancellations_intro = "keeper.world.task_cancellations.intro"
let keeper_world_own_recent_actions_heading = "keeper.world.own_recent_actions.heading"
let keeper_world_own_recent_actions_intro = "keeper.world.own_recent_actions.intro"

let keeper_world_own_recent_actions_turn_ok_row =
  "keeper.world.own_recent_actions.turn_ok_row"
;;

let keeper_world_own_recent_actions_turn_rejected_row =
  "keeper.world.own_recent_actions.turn_rejected_row"
;;

let keeper_world_own_recent_actions_turn_rejected_detail_row =
  "keeper.world.own_recent_actions.turn_rejected_detail_row"
;;

let keeper_world_pending_messages_heading = "keeper.world.pending_messages.heading"
let keeper_world_pending_messages_intro = "keeper.world.pending_messages.intro"

let keeper_world_pending_messages_mention_row =
  "keeper.world.pending_messages.mention_row"
;;

let keeper_world_pending_messages_scope_row = "keeper.world.pending_messages.scope_row"
let keeper_world_own_board_posts_heading = "keeper.world.own_board_posts.heading"
let keeper_world_own_board_posts_intro = "keeper.world.own_board_posts.intro"
let keeper_world_board_activity_heading = "keeper.world.board_activity.heading"
let keeper_world_board_activity_intro = "keeper.world.board_activity.intro"
let keeper_world_fleet_messages_heading = "keeper.world.fleet_messages.heading"
let keeper_world_fleet_messages_intro = "keeper.world.fleet_messages.intro"
let keeper_world_fleet_messages_row = "keeper.world.fleet_messages.row"

(* Event-row titles and previews, rendered when the observation is created
   rather than when the prompt is assembled. *)
let keeper_world_event_rows_fusion_title_succeeded =
  "keeper.world.event_rows.fusion_title_succeeded"
;;

let keeper_world_event_rows_fusion_title_failed =
  "keeper.world.event_rows.fusion_title_failed"
;;

let keeper_world_event_rows_fusion_title_cancelled =
  "keeper.world.event_rows.fusion_title_cancelled"
;;

let keeper_world_event_rows_fusion_cancelled_preview =
  "keeper.world.event_rows.fusion_cancelled_preview"
;;

let keeper_world_event_rows_scheduled_wake_title =
  "keeper.world.event_rows.scheduled_wake_title"
;;

let keeper_world_event_rows_external_attention_title =
  "keeper.world.event_rows.external_attention_title"
;;

let keeper_world_event_rows_ask_title = "keeper.world.event_rows.ask_title"
let keeper_world_event_rows_ask_skipped = "keeper.world.event_rows.ask_skipped"

let keeper_world_event_rows_completion_authority_title =
  "keeper.world.event_rows.completion_authority_title"
;;

let keeper_world_event_rows_completion_authority_preview =
  "keeper.world.event_rows.completion_authority_preview"
;;

let keeper_world_event_rows_task_cancelled_title =
  "keeper.world.event_rows.task_cancelled_title"
;;

let keeper_world_event_rows_task_cancelled_preview =
  "keeper.world.event_rows.task_cancelled_preview"
;;

let keeper_world_event_rows_task_cancelled_no_reason =
  "keeper.world.event_rows.task_cancelled_no_reason"
;;

(* Tool failure next-move sentences, one per Tool_result.tool_failure_class. *)
let tool_failure_dependency_unavailable = "tool_failure.dependency_unavailable"
let tool_failure_policy_rejection = "tool_failure.policy_rejection"
let tool_failure_runtime_failure = "tool_failure.runtime_failure"
let tool_failure_workflow_rejection = "tool_failure.workflow_rejection"
let tool_failure_operator_cancelled = "tool_failure.operator_cancelled"

(* Gate replay delivery wording — one key per replay evidence state and one
   per resolution path, following the keeper.observation.* precedent. The
   model-facing instruction lives in the template; the execution path only
   picks the key and supplies the evidence data. *)
let keeper_gate_replay_evidence_applied = "keeper.gate_replay.evidence.applied"

let keeper_gate_replay_evidence_applied_with_warning =
  "keeper.gate_replay.evidence.applied_with_warning"
;;

let keeper_gate_replay_evidence_failed = "keeper.gate_replay.evidence.failed"

let keeper_gate_replay_evidence_indeterminate =
  "keeper.gate_replay.evidence.indeterminate"
;;

let keeper_gate_replay_repair_required = "keeper.gate_replay.repair_required"

let keeper_gate_replay_resolution_without_replay_outcome =
  "keeper.gate_replay.resolution_without_replay_outcome"
;;

let keeper_gate_replay_resolution_exact_input =
  "keeper.gate_replay.resolution_exact_input"
;;

(* HITL context-summary canonical output contract — the schema is data the
   caller supplies; the contract sentence lives in the template. *)
let judge_effect_output_contract = "judge.effect.output_contract"

(* Tool-help registry fallback prose and markdown scaffold — shared wording,
   not per-tool data (per-tool authored help lives in config/tools/<name>.toml
   [help]). The derivation path for a tool without [help] renders these; the
   execution path only picks the key and supplies the entry data. *)
let tool_help_prompt_hint_tool_help = "tool_help.prompt_hint.tool_help"
let tool_help_when_to_use_tool_help = "tool_help.when_to_use.tool_help"
let tool_help_when_to_use_generic = "tool_help.when_to_use.generic"
let tool_help_constraint_hidden = "tool_help.constraint.hidden"
let tool_help_constraint_placeholder = "tool_help.constraint.placeholder"
let tool_help_constraint_simulation = "tool_help.constraint.simulation"
let tool_help_constraint_adapter = "tool_help.constraint.adapter"
let tool_help_short_description_empty = "tool_help.short_description.empty"
let tool_help_entry_header = "tool_help.entry.header"
let tool_help_entry_when_to_use = "tool_help.entry.when_to_use"
let tool_help_entry_key_constraints = "tool_help.entry.key_constraints"
let tool_help_entry_details = "tool_help.entry.details"
let tool_help_entry_docs = "tool_help.entry.docs"
let tool_help_entry_prompt_hints = "tool_help.entry.prompt_hints"
let tool_help_entry_examples = "tool_help.entry.examples"
let tool_help_entry_alternatives = "tool_help.entry.alternatives"
let tool_help_index_header = "tool_help.index.header"

(* Tool-result guidance (RFC prompts-and-tool-definitions-outside-ocaml §3.11):
   each closed variant arm maps to exactly one key here; the prose lives in
   the group file, and the execution path only picks the variant and supplies
   the data. *)

(* keeper.tool_filesystem.* — Keeper filesystem tool-result wording
   (keeper_tool_filesystem_runtime.fs_guidance). *)
let keeper_tool_filesystem_offset_not_1_based =
  "keeper.tool_filesystem.offset_not_1_based"
;;

let keeper_tool_filesystem_limit_not_positive =
  "keeper.tool_filesystem.limit_not_positive"
;;

let keeper_tool_filesystem_available_cwds_partial =
  "keeper.tool_filesystem.available_cwds_partial"
;;

let keeper_tool_filesystem_checkout_scan_failed =
  "keeper.tool_filesystem.checkout_scan_failed"
;;

let keeper_tool_filesystem_cwd_not_directory = "keeper.tool_filesystem.cwd_not_directory"

let keeper_tool_filesystem_offset_beyond_window =
  "keeper.tool_filesystem.offset_beyond_window"
;;

let keeper_tool_filesystem_offset_beyond_scan_budget =
  "keeper.tool_filesystem.offset_beyond_scan_budget"
;;

let keeper_tool_filesystem_capability_unavailable =
  "keeper.tool_filesystem.capability_unavailable"
;;

let keeper_tool_filesystem_publication_failed =
  "keeper.tool_filesystem.publication_failed"
;;

let keeper_tool_filesystem_directory_publication_failed =
  "keeper.tool_filesystem.directory_publication_failed"
;;

let keeper_tool_filesystem_append_capability_failed =
  "keeper.tool_filesystem.append_capability_failed"
;;

let keeper_tool_filesystem_append_incomplete = "keeper.tool_filesystem.append_incomplete"

let keeper_tool_filesystem_recovery_lane_committed =
  "keeper.tool_filesystem.recovery_lane_committed"
;;

let keeper_tool_filesystem_recovery_lane_effect_observed =
  "keeper.tool_filesystem.recovery_lane_effect_observed"
;;

let keeper_tool_filesystem_recovery_lane_not_executed =
  "keeper.tool_filesystem.recovery_lane_not_executed"
;;

let keeper_tool_filesystem_recovery_lane_indeterminate =
  "keeper.tool_filesystem.recovery_lane_indeterminate"
;;

let keeper_tool_filesystem_recovery_lane_cleanup_detail =
  "keeper.tool_filesystem.recovery_lane_cleanup_detail"
;;

let keeper_tool_filesystem_gate_record_unavailable =
  "keeper.tool_filesystem.gate_record_unavailable"
;;

let keeper_tool_filesystem_path_required = "keeper.tool_filesystem.path_required"

let keeper_tool_filesystem_patch_requires_old_string =
  "keeper.tool_filesystem.patch_requires_old_string"
;;

let keeper_tool_filesystem_patch_target_missing =
  "keeper.tool_filesystem.patch_target_missing"
;;

(* keeper.gate_replay.* — one slot per replay resolution state / artifact
   integrity failure; composed per state arm, never one shared template. *)
let keeper_gate_replay_resolution_consumed_without_outcome =
  "keeper.gate_replay.resolution_consumed_without_outcome"
;;

let keeper_gate_replay_resolution_invalid_replay_state =
  "keeper.gate_replay.resolution_invalid_replay_state"
;;

let keeper_gate_replay_resolution_journal_unreadable =
  "keeper.gate_replay.resolution_journal_unreadable"
;;

let keeper_gate_replay_resolution_rejected = "keeper.gate_replay.resolution_rejected"
let keeper_gate_replay_artifact_missing = "keeper.gate_replay.artifact_missing"

let keeper_gate_replay_artifact_length_mismatch =
  "keeper.gate_replay.artifact_length_mismatch"
;;

let keeper_gate_replay_approval_input_drifted =
  "keeper.gate_replay.approval_input_drifted"
;;

let keeper_gate_replay_approval_consumption_mismatch =
  "keeper.gate_replay.approval_consumption_mismatch"
;;

let keeper_gate_replay_replay_outcome_missing_after_restart =
  "keeper.gate_replay.replay_outcome_missing_after_restart"
;;

let keeper_gate_replay_replay_outcome_before_consumption =
  "keeper.gate_replay.replay_outcome_before_consumption"
;;

let keeper_gate_replay_replay_effect_raised = "keeper.gate_replay.replay_effect_raised"

(* exec_policy.* — the short block reasons surfaced via
   [Exec_policy.block_reason_to_string] and the cwd sibling-dirs hint. *)
let exec_policy_block_reason_empty_command = "exec_policy.block_reason.empty_command"

let exec_policy_block_reason_process_substitution =
  "exec_policy.block_reason.process_substitution"
;;

let exec_policy_block_reason_pipes_not_allowed =
  "exec_policy.block_reason.pipes_not_allowed"
;;

let exec_policy_cwd_existing_siblings_hint = "exec_policy.cwd_existing_siblings_hint"

(* subset_rewrite.* — the advice templates [Subset_rewrite.to_string]
   renders around the caller-supplied [because]. *)
let subset_rewrite_move_to_field = "subset_rewrite.move_to_field"
let subset_rewrite_call_this_instead = "subset_rewrite.call_this_instead"
let subset_rewrite_spell_it_as = "subset_rewrite.spell_it_as"

(* tool_guidance.* — generic cross-domain tool-result guidance, one arm of
   [Tool_guidance.t] per key. *)
let tool_guidance_broadcast_delivery_rejected =
  "tool_guidance.broadcast_delivery_rejected"
;;

let tool_guidance_broadcast_content_required = "tool_guidance.broadcast_content_required"

let tool_guidance_workspace_message_delivery_rejected =
  "tool_guidance.workspace_message_delivery_rejected"
;;

let tool_guidance_post_execution_hook_failed = "tool_guidance.post_execution_hook_failed"
let tool_guidance_mcp_outcome_unknown = "tool_guidance.mcp_outcome_unknown"

let tool_guidance_reject_verdict_requires_reason =
  "tool_guidance.reject_verdict_requires_reason"
;;

let tool_guidance_no_metrics_found_for_agent = "tool_guidance.no_metrics_found_for_agent"
let tool_guidance_invalid_agent_card_action = "tool_guidance.invalid_agent_card_action"

(* agent_core.* — templates the host installs into
   [Agent_core.Tool_guidance_text] at prompt-init time; agent_core itself
   stays config-free. *)
let agent_core_unknown_tool_not_found = "agent_core.unknown_tool.not_found"

let agent_core_unknown_tool_not_found_no_tools =
  "agent_core.unknown_tool.not_found_no_tools"
;;

let agent_core_unknown_tool_closest_registered =
  "agent_core.unknown_tool.closest_registered"
;;

let agent_core_unknown_tool_extra_characters = "agent_core.unknown_tool.extra_characters"

let agent_core_unknown_tool_not_bare_with_closest =
  "agent_core.unknown_tool.not_bare_with_closest"
;;

let agent_core_unknown_tool_not_bare = "agent_core.unknown_tool.not_bare"
let agent_core_handoff_description = "agent_core.handoff.description"

let agent_core_handoff_prompt_param_description =
  "agent_core.handoff.prompt_param_description"
;;

let agent_core_agent_tool_prompt_param_description =
  "agent_core.agent_tool.prompt_param_description"
;;
