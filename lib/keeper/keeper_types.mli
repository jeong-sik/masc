(** Keeper_types -- shared keeper contract, registry/store helpers,
    path resolution, and model-selection utilities.

    Re-exports everything from {!Keeper_types_profile} (context, schemas,
    profile defaults, path helpers) and {!Keeper_types_support}
    (model selection, JSONL helpers, metrics store). *)

include module type of Keeper_types_profile

(** {1 Policy types (remain in keeper_meta top-level)} *)

type compaction_policy = {
  profile: string;
  ratio_gate: float;
  message_gate: int;
  token_gate: int;
  cooldown_sec: int;
  max_checkpoint_messages: int;
}

type proactive_policy = {
  enabled: bool;
  idle_sec: int;
  cooldown_sec: int;
}

type scheduled_autonomous_policy = proactive_policy

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error

type scheduled_autonomous_cycle_outcome = proactive_cycle_outcome

type tool_preset =
  | Minimal
  | Social
  | Messaging
  | Coding
  | Research
  | Delivery
  | Full

type tool_access =
  | Preset of {
      preset : tool_preset;
      also_allow : string list;
    }
  | Custom of string list

(** {1 Runtime types (embedded in agent_runtime_state)} *)

type compaction_runtime = {
  count: int;
  last_ts: float;
  last_before_tokens: int;
  last_after_tokens: int;
  last_check_ts: float;
  last_decision: string;
}

type proactive_runtime = {
  count_total: int;
  last_ts: float;
  visible_count_total: int;
  last_visible_ts: float;
  last_outcome: proactive_cycle_outcome;
  last_reason: string;
  last_preview: string;
  last_work_discovery_ts : float;
  work_discovery_count : int;
  consecutive_noop_count : int;
}

type scheduled_autonomous_runtime = proactive_runtime

type usage_metrics = {
  total_turns: int;
  total_input_tokens: int;
  total_output_tokens: int;
  total_tokens: int;
  total_cost_usd: float;
  last_turn_ts: float;
  last_model_used: string;
  last_input_tokens: int;
  last_output_tokens: int;
  last_total_tokens: int;
  last_latency_ms: int;
}

(** {1 Agent runtime state} *)

(** Structured blocker classification — replaces string-based error matching. *)
type cascade_exhaustion_reason =
  | Connection_refused
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Other_detail of string

type blocker_class =
  | Cascade_exhausted of cascade_exhaustion_reason
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Completion_contract_violation
  | No_tool_capable_provider

val blocker_class_to_string : blocker_class -> string
val cascade_exhaustion_summary : cascade_exhaustion_reason -> string
val blocker_class_continue_gate : blocker_class -> bool
val cascade_exhaustion_reason_to_json : cascade_exhaustion_reason -> Yojson.Safe.t
val cascade_exhaustion_reason_of_json : Yojson.Safe.t -> cascade_exhaustion_reason option

type agent_runtime_state = {
  usage: usage_metrics;
  compaction_rt: compaction_runtime;
  proactive_rt: proactive_runtime;
  generation: int;
  trace_id: Keeper_id.Trace_id.t;
  trace_history: string list;
  last_handoff_ts: float;
  last_continuity_update_ts: float;
  last_autonomous_action_at: string;
  autonomous_action_count: int;
  autonomous_turn_count: int;
  autonomous_text_turn_count: int;
  autonomous_tool_turn_count: int;
  board_reactive_turn_count: int;
  mention_reactive_turn_count: int;
  noop_turn_count: int;
  consecutive_noop_count: int;
  last_speech_act: string;
  last_social_transition_reason: string;
  last_active_desire: string;
  last_current_intention: string;
  last_blocker: string;
  last_blocker_class: blocker_class option;
  last_need: string;
}

(** {1 Keeper meta} *)

type keeper_meta = {
  name: string;
  agent_name: string;
  goal: string;
  short_goal: string;
  mid_goal: string;
  long_goal: string;
  social_model: string;
  cascade_name: string;
  models: string list;
  will: string;
  needs: string;
  desires: string;
  instructions: string;
  policy_voice_enabled: bool;
  execution_scope: Keeper_execution_scope.t;
  sandbox_profile: sandbox_profile;
  network_mode: network_mode;
  shared_memory_scope: shared_memory_scope;
  allowed_paths: string list;
  tool_access: tool_access;
  tool_denylist: string list;
  mention_targets: string list;
  room_signal_prompt_enabled: bool;
  joined_room_ids: string list;
  last_seen_seq_by_room: (string * int) list;
  proactive: proactive_policy;
  compaction: compaction_policy;
  auto_handoff: bool;
  handoff_threshold: float;
  handoff_cooldown_sec: int;
  voice_enabled: bool;
  voice_channel: string;
  voice_agent_id: string;
  created_at: string;
  updated_at: string;
  max_context_override: int option;
  continuity_summary: string;
  active_goal_ids: string list;
  paused: bool;
  autoboot_enabled: bool;
  current_task_id: Keeper_id.Task_id.t option;
  (** Currently claimed task ID for cost attribution. *)
  work_discovery_enabled : bool option;
  work_discovery_sources : string list option;
  work_discovery_interval_sec : int option;
  work_discovery_guidance : string option;
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  runtime: agent_runtime_state;
}

val default_social_model : string

val now_iso : unit -> string

val tool_preset_to_string : tool_preset -> string
val tool_preset_of_string : string -> tool_preset option

val all_tool_presets : tool_preset list
(** Issue #8430: complete list of [tool_preset] constructors in
    declaration order. Adding an 8th constructor will fail to compile
    in [tool_preset_to_string] and in the witness test. *)

val valid_tool_preset_strings : string list
(** Issue #8430: canonical strings for every [tool_preset] constructor
    via [tool_preset_to_string]. Schema authors should mirror or
    consume this; see [Keeper_schema.tool_preset_enum_strings] which
    keeps a synced copy due to a build-graph cycle. *)

val proactive_cycle_outcome_to_string : proactive_cycle_outcome -> string
val proactive_cycle_outcome_of_string : string -> proactive_cycle_outcome
val scheduled_autonomous_cycle_outcome_to_string :
  scheduled_autonomous_cycle_outcome -> string
val scheduled_autonomous_cycle_outcome_of_string :
  string -> scheduled_autonomous_cycle_outcome
val tool_access_preset : tool_access -> tool_preset option
val tool_access_custom_allowlist : tool_access -> string list option
val tool_access_also_allowlist : tool_access -> string list
val tool_access_to_json : tool_access -> Yojson.Safe.t
val tool_access_of_meta_json : Yojson.Safe.t -> (tool_access, string) result

(** {1 Updater helpers for nested record updates} *)

val map_runtime : (agent_runtime_state -> agent_runtime_state) -> keeper_meta -> keeper_meta
val map_usage : (usage_metrics -> usage_metrics) -> keeper_meta -> keeper_meta
val zero_usage : usage_metrics
val reset_runtime_state : keeper_meta -> keeper_meta
val map_compaction_rt : (compaction_runtime -> compaction_runtime) -> keeper_meta -> keeper_meta
val map_proactive_rt : (proactive_runtime -> proactive_runtime) -> keeper_meta -> keeper_meta
val map_scheduled_autonomous_rt :
  (scheduled_autonomous_runtime -> scheduled_autonomous_runtime) ->
  keeper_meta -> keeper_meta

(** {1 Legacy model arg rejection} *)

val keeper_legacy_model_arg_names : string list

val reject_legacy_model_args :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result

(** {1 Runtime meta write sync hook} *)

val runtime_meta_write_sync_hook : (Coord.config -> keeper_meta -> unit) ref
val register_runtime_meta_write_sync : (Coord.config -> keeper_meta -> unit) -> unit

(** {1 JSON field scrubbing} *)

val drop_assoc_keys : string list -> Yojson.Safe.t -> Yojson.Safe.t
val reject_removed_keeper_meta_fields : Yojson.Safe.t -> (unit, string) result
val scrub_persisted_keeper_meta_json :
  path:string -> Yojson.Safe.t -> Yojson.Safe.t * bool

(** {1 Meta serialization} *)

val meta_to_json : keeper_meta -> Yojson.Safe.t
val meta_of_json : Yojson.Safe.t -> (keeper_meta, string) result

(** {1 Meta file I/O} *)

val read_meta_file_path : string -> (keeper_meta option, string) result
val persisted_keeper_names : Coord.config -> string list
val configured_keeper_names : Coord.config -> string list
val keeper_names : Coord.config -> string list
val keepalive_keeper_names : Coord.config -> string list
val persistent_agent_names : Coord.config -> string list
val fresher_meta : Coord.config -> keeper_meta -> keeper_meta
val write_meta : ?force:bool -> Coord.config -> keeper_meta -> (unit, string) result
val keeper_name_from_agent_name : string -> string option
val canonical_keeper_name_from_agent_name : string -> string option
val canonical_keeper_name : string -> string option
val read_meta_resolved :
  Coord.config -> string -> ((string * keeper_meta) option, string) result
val read_meta : Coord.config -> string -> (keeper_meta option, string) result

(** Read keeper meta only if the file's mtime changed since [last_mtime].
    Returns [Some (meta, new_mtime)] on change, [None] when unchanged.
    Avoids JSON parsing on every heartbeat when no operator modified the file. *)
val read_meta_if_changed :
  Coord.config -> string -> last_mtime:float ->
  (keeper_meta * float) option

(** {1 Re-exports from Keeper_types_support} *)

include module type of Keeper_types_support

(** {1 Fiber health (for keeper supervisor)} *)

type fiber_health =
  | Fiber_alive
  | Fiber_zombie
  | Fiber_dead
  | Fiber_unknown

(** {1 Keeper health state} *)

type keeper_health =
  | KH_healthy
  | KH_idle
  | KH_offline
  | KH_stale
  | KH_degraded
  | KH_zombie
  | KH_dead

type keeper_continuity =
  | Continuity_healthy
  | Continuity_recovering
  | Continuity_not_running

(** {1 Per-tool usage tracking} *)

type tool_call_entry = {
  count : int;
  successes : int;
  failures : int;
  last_used_at : float;
}

(** {1 Working Context Types (moved from Keeper_working_context)} *)

type working_context = {
  checkpoint : Agent_sdk.Checkpoint.t;
  max_tokens : int;
}

type checkpoint = {
  checkpoint_id : string;
  timestamp : float;
  generation : int;
  message_count : int;
  token_count : int;
  serialized : string;
}

type session_context = {
  session_id : string;
  session_dir : string;
  mutable checkpoints : checkpoint list;
}
