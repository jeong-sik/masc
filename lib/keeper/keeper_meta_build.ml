(** Keeper_meta_build — pure construction of the initial [keeper_meta].

    Every non-deterministic or environment-derived input (clock value, keeper
    uid, generation counter, trace id, compaction mode default) is injected by
    the caller: this module performs no I/O, reads no config, and mutates
    nothing. The boot-time create path (Keeper_turn_up_create) and any
    create-without-boot path build their initial metadata through this one
    function, so the two paths cannot drift field-by-field. *)

open Keeper_meta_contract

let initial_meta ~name ~agent_name ~persona_extended ~goal ~instructions
    ~sandbox_profile ~network_mode ~multimodal_policy ~allowed_paths
    ~mention_targets ~proactive_enabled ~compaction_profile ~compaction_mode
    ~compaction_ratio_gate ~compaction_message_gate ~compaction_token_gate
    ~compaction_cooldown_sec ~auto_handoff ~handoff_threshold
    ~handoff_cooldown_sec ~created_at ~max_context_override ~active_goal_ids
    ~autoboot_enabled ~telemetry_feedback_enabled
    ~telemetry_feedback_window_hours ~always_allow ~now_ts ~generation
    ~trace_id ~keeper_uid ~oas_env () : keeper_meta =
  {
    id = None;
    name;
    agent_name;
    persona = Some persona_extended;
    goal;
    instructions;
    sandbox_profile;
    sandbox_image = None;
    network_mode;
    multimodal_policy;
    allowed_paths;
    mention_targets;
    proactive = { enabled = proactive_enabled };
    compaction =
      {
        profile = compaction_profile;
        mode = compaction_mode;
        ratio_gate = compaction_ratio_gate;
        message_gate = compaction_message_gate;
        token_gate = compaction_token_gate;
        cooldown_sec = compaction_cooldown_sec;
      };
    auto_handoff;
    handoff_threshold;
    handoff_cooldown_sec;
    (* One injected instant for both stamps: a freshly built meta cannot have
       been updated after it was created. *)
    created_at;
    updated_at = created_at;
    max_context_override;
    active_goal_ids;
    paused = false;
    latched_reason = None;
    autoboot_enabled;
    current_task_id = None;
    telemetry_feedback_enabled;
    telemetry_feedback_window_hours;
    always_allow;
    runtime =
      {
        usage =
          {
            total_turns = 0;
            total_input_tokens = 0;
            total_output_tokens = 0;
            total_tokens = 0;
            total_cost_usd = 0.0;
            last_turn_ts = 0.0;
            last_input_tokens = 0;
            last_output_tokens = 0;
            last_total_tokens = 0;
            last_latency_ms = 0;
          };
        compaction_rt =
          {
            count = 0;
            last_ts = 0.0;
            last_before_tokens = 0;
            last_after_tokens = 0;
            last_check_ts = now_ts;
            last_decision = compaction_runtime_decision_of_string "initialized";
          };
        proactive_rt =
          {
            count_total = 0;
            last_ts = 0.0;
            visible_count_total = 0;
            last_visible_ts = 0.0;
            last_outcome = Proactive_never_started;
            last_reason = "";
            last_preview = "";
            consecutive_noop_count = 0;
          };
        generation;
        trace_id;
        trace_history = [];
        last_handoff_ts = 0.0;
        last_autonomous_action_at = "";
        autonomous_action_count = 0;
        autonomous_turn_count = 0;
        autonomous_text_turn_count = 0;
        autonomous_tool_turn_count = 0;
        board_reactive_turn_count = 0;
        mention_reactive_turn_count = 0;
        noop_turn_count = 0;
        message_scope_ack_id = None;
        last_blocker = None;
        last_runtime_attempt = None;
        last_turn_tool_calls = [];
      };
    keeper_id = Some keeper_uid;
    oas_env;
    meta_version = 0;
  }
