(** Keeper_meta_contract — Keeper meta policy + runtime contract
    types and pure helpers.

    Included by {!Keeper_types} so existing [Keeper_types.*]
    callers keep their public API.  This module separates the
    type-heavy contract from JSON parsing
    ({!Keeper_meta_json}) and store I/O.

    Re-exports {!Keeper_meta_tool_access} via [include] for the
    [tool_preset] / [tool_access] ADT — callers can reach those
    via either {!Keeper_types.tool_preset} or
    {!Keeper_meta_contract.tool_preset} interchangeably (type
    identity preserved through the cascade).

    Internal: ~5 helpers stay private —
    \[blocker_class_of_serialized_string] (deserializer used
    only by JSON parsing), \[scheduled_autonomous_cycle_outcome_to_string]
    / \[scheduled_autonomous_cycle_outcome_of_string] (aliases
    of the proactive_cycle_outcome counterparts kept available
    for the [include] cascade), \[map_compaction_rt] /
    \[map_proactive_rt] / \[map_scheduled_autonomous_rt]
    (nested-record updaters that callers reach via the higher-level
    {!map_runtime} / {!map_usage}), \[keeper_legacy_model_arg_names]
    (data table consumed by the legacy-arg rejector in
    {!Keeper_types}).  All consumed only via the include
    cascade or the JSON pipeline. *)

(** {1 Tool-access cascade re-export} *)

include module type of Keeper_meta_tool_access

(** {1 Policy types} *)

type compaction_policy = {
  profile : string;
  ratio_gate : float;
  message_gate : int;
  token_gate : int;
  cooldown_sec : int;
  max_checkpoint_messages : int;
}

type proactive_policy = {
  enabled : bool;
  idle_sec : int;
  cooldown_sec : int;
}

type scheduled_autonomous_policy = proactive_policy
(** Alias preserved for callers that reach the type via the
    older name.  Drift would break legacy keeper persona files. *)

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error
(** Outcome variants for a single proactive (autonomous) cycle.
    Round-trip enforced at module load time
    ([proactive_cycle_outcome_to_string] +
    [proactive_cycle_outcome_of_string] must form a bijection)
    via an [assert_roundtrip] block — adding a variant fails
    compile until both directions are wired. *)

type scheduled_autonomous_cycle_outcome = proactive_cycle_outcome

(** {1 Runtime state types} *)

type compaction_runtime_decision = Compaction_runtime_decision of string
(** Last compaction gate result as persisted in keeper meta.  JSON and
    dashboard boundaries still use the historical string value via
    {!compaction_runtime_decision_to_string}. *)

val compaction_runtime_decision_to_string :
  compaction_runtime_decision -> string

val compaction_runtime_decision_of_string :
  string -> compaction_runtime_decision

type compaction_runtime = {
  count : int;
  last_ts : float;
  last_before_tokens : int;
  last_after_tokens : int;
  last_check_ts : float;
  last_decision : compaction_runtime_decision;
}

type proactive_runtime = {
  count_total : int;
  last_ts : float;
  visible_count_total : int;
  last_visible_ts : float;
  last_outcome : proactive_cycle_outcome;
  last_reason : string;
  last_preview : string;
  last_work_discovery_ts : float;
  work_discovery_count : int;
  consecutive_noop_count : int;
      (** Consecutive autonomous cycles where only observation
          tools were used with no substantive action.  Used by
          [effective_scheduled_autonomous_cooldown] for
          exponential backoff: cooldown *= 2^min(n, 3),
          capping at 8x.  Resets on any productive cycle. *)
}

type scheduled_autonomous_runtime = proactive_runtime

type usage_metrics = {
  total_turns : int;
  total_input_tokens : int;
  total_output_tokens : int;
  total_tokens : int;
  total_cost_usd : float;
  last_turn_ts : float;
  last_model_used : string;
  last_input_tokens : int;
  last_output_tokens : int;
  last_total_tokens : int;
  last_latency_ms : int;
}

(** {1 Blocker classification} *)

type cascade_exhaustion_reason =
  | Connection_refused
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Other_detail of string

type blocker_class =
  | Cascade_exhausted of cascade_exhaustion_reason
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Oas_timeout_budget
  | Turn_timeout
  | Completion_contract_violation
  | No_tool_capable_provider

val blocker_class_to_string : blocker_class -> string
(** Canonical lowercase labels.  Pinned literals — operator
    dashboards parse these for keeper supervisor alerting. *)

val cascade_exhaustion_summary :
  cascade_exhaustion_reason -> string
(** Human-readable one-sentence summary per reason variant.
    Used in keeper supervisor logs + dashboard tooltips. *)

val blocker_class_continue_gate : blocker_class -> bool
(** [blocker_class_continue_gate b] is [true] iff the supervisor
    should retry past this blocker.  Currently only
    [Ambiguous_post_commit_timeout] and
    [Ambiguous_post_commit_failure] are continue-gated — every
    other blocker terminates the keeper.  Pinned at the
    contract seam — drift changes keeper recovery semantics. *)

val cascade_exhaustion_reason_to_json :
  cascade_exhaustion_reason -> Yojson.Safe.t

val cascade_exhaustion_reason_of_json :
  Yojson.Safe.t -> cascade_exhaustion_reason option

val blocker_class_of_serialized_string :
  string -> blocker_class option
(** [blocker_class_of_serialized_string label] is the inverse
    of {!blocker_class_to_string}.  [Cascade_exhausted _]
    maps from the bare ["cascade_exhausted"] string to
    [Cascade_exhausted (Other_detail "cascade_exhausted")] —
    the reason payload is not round-trippable through this
    function alone (callers needing the reason use
    {!cascade_exhaustion_reason_of_json}).  Used by
    {!Keeper_meta_json_parse} to decode persisted blocker
    state. *)

(** {1 Agent runtime state record} *)

type agent_runtime_state = {
  usage : usage_metrics;
  compaction_rt : compaction_runtime;
  proactive_rt : proactive_runtime;
  generation : int;
  trace_id : Keeper_id.Trace_id.t;
  trace_history : string list;
  last_handoff_ts : float;
  last_continuity_update_ts : float;
  last_autonomous_action_at : string;
  autonomous_action_count : int;
  autonomous_turn_count : int;
  autonomous_text_turn_count : int;
  autonomous_tool_turn_count : int;
  board_reactive_turn_count : int;
  mention_reactive_turn_count : int;
  noop_turn_count : int;
  consecutive_noop_count : int;
  last_speech_act : string;
  last_social_transition_reason : string;
  last_active_desire : string;
  last_current_intention : string;
  last_blocker : string;
  last_blocker_class : blocker_class option;
  last_need : string;
}

(** {1 Keeper meta record} *)

type keeper_meta = {
  (* Identity & profile *)
  id : Ids.Keeper_id.t option;
  name : string;
  agent_name : string;
  goal : string;
  short_goal : string;
  mid_goal : string;
  long_goal : string;
  social_model : string;
  cascade_name : string;
  models : string list;
  will : string;
  needs : string;
  desires : string;
  instructions : string;
  (* Policy *)
  policy_voice_enabled : bool;
  sandbox_profile : Keeper_types_profile.sandbox_profile;
  sandbox_image : string option;
  network_mode : Keeper_types_profile.network_mode;
  shared_memory_scope : Keeper_types_profile.shared_memory_scope;
  allowed_paths : string list;
  tool_access : tool_access;
  tool_preset_source : string option;
  tool_denylist : string list;
  mention_targets : string list;
  room_signal_prompt_enabled : bool;
  joined_room_ids : string list;
  last_seen_seq_by_room : (string * int) list;
  proactive : proactive_policy;
  compaction : compaction_policy;
  auto_handoff : bool;
  handoff_threshold : float;
  handoff_cooldown_sec : int;
  (* Voice *)
  voice_enabled : bool;
  voice_channel : string;
  voice_agent_id : string;
  (* Lifecycle *)
  created_at : string;
  updated_at : string;
  (* Performance & limits *)
  max_context_override : int option;
  (* Operational control *)
  continuity_summary : string;
  active_goal_ids : string list;
  paused : bool;
  autoboot_enabled : bool;
  current_task_id : Keeper_id.Task_id.t option;
      (** Currently claimed task ID for cost attribution.  Set
          when keeper claims a task; cleared on
          masc_transition action=done.  Propagated to
          trajectory accumulator for per-task cost tracking. *)
  work_discovery_enabled : bool option;
  work_discovery_sources : string list option;
  work_discovery_interval_sec : int option;
  work_discovery_guidance : string option;
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  per_provider_timeout_s : float option;
  always_approve : bool option;
  (* Agent runtime state *)
  runtime : agent_runtime_state;
  (* Identity & concurrency *)
  keeper_id : Keeper_id.Uid.t option;
  oas_env : (string * string) list;
  meta_version : int;
}

(** {1 Outcome <-> string} *)

val proactive_cycle_outcome_to_string :
  proactive_cycle_outcome -> string
(** Canonical lowercase labels: ["never_started"], ["unknown"],
    ["silent"], ["text_response"], ["tool_use"],
    ["mixed_response"], ["error"]. *)

val proactive_cycle_outcome_of_string :
  string -> proactive_cycle_outcome
(** Permissive parser (case-insensitive after trim).  Unknown
    labels fall back to [Proactive_unknown] — but module-load
    [assert_roundtrip] guarantees every variant produced by
    [_to_string] is parsed back identically, so unknown means
    operator error, not silent variant drift. *)

val scheduled_autonomous_cycle_outcome_to_string :
  scheduled_autonomous_cycle_outcome -> string
(** Alias of {!proactive_cycle_outcome_to_string} preserved for
    callers that reach the symbol via the older name.  Same
    canonical labels. *)

val scheduled_autonomous_cycle_outcome_of_string :
  string -> scheduled_autonomous_cycle_outcome
(** Alias of {!proactive_cycle_outcome_of_string}. *)

(** {1 Updater helpers} *)

val now_iso : unit -> string
(** [now_iso ()] is the ISO-8601 timestamp from
    {!Types.now_iso}. *)

val map_runtime :
  (agent_runtime_state -> agent_runtime_state) ->
  keeper_meta ->
  keeper_meta
(** [map_runtime f m] returns [{ m with runtime = f m.runtime }] —
    pure functional update of the runtime sub-record. *)

val map_usage :
  (usage_metrics -> usage_metrics) ->
  keeper_meta ->
  keeper_meta
(** [map_usage f m] is [map_runtime (fun rt -> { rt with usage =
    f rt.usage }) m] — convenience for usage-only updates. *)

val zero_usage : usage_metrics
(** [zero_usage] is the all-zero usage_metrics record.  Pinned
    at the contract seam — drift would change "fresh keeper"
    initial state. *)

val reset_runtime_state : keeper_meta -> keeper_meta
(** [reset_runtime_state m] is [map_usage (fun _ -> zero_usage)
    m] — used by keeper restart to clear cumulative counters
    while preserving identity / policy fields. *)

val map_compaction_rt :
  (compaction_runtime -> compaction_runtime) ->
  keeper_meta ->
  keeper_meta
(** Nested update of [m.runtime.compaction_rt]. *)

val map_proactive_rt :
  (proactive_runtime -> proactive_runtime) ->
  keeper_meta ->
  keeper_meta
(** Nested update of [m.runtime.proactive_rt]. *)

val map_scheduled_autonomous_rt :
  (scheduled_autonomous_runtime ->
   scheduled_autonomous_runtime) ->
  keeper_meta ->
  keeper_meta
(** Alias of {!map_proactive_rt} preserved for the older
    ([scheduled_autonomous_*]) call-site naming. *)

(** {1 Legacy model-arg sentinel list} *)

val keeper_legacy_model_arg_names : string list
(** Names of legacy keeper-creation tool arguments that have
    been retired in favour of the [cascade_name] field
    (["models"], ["allowed_models"], ["active_model"]).
    Consumed by {!Keeper_types.reject_legacy_model_args} which
    surfaces operator-readable rejection messages instead of
    silently ignoring deprecated args.  Pinned data table —
    drift would either re-accept retired args silently or
    reject newly added args by mistake. *)
