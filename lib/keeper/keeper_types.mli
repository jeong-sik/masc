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
}

type proactive_policy = {
  enabled: bool;
  idle_sec: int;
  cooldown_sec: int;
}

type tool_access =
  | Unrestricted
  | Restricted of string list

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
  last_reason: string;
  last_preview: string;
}

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

type agent_runtime_state = {
  usage: usage_metrics;
  compaction_rt: compaction_runtime;
  proactive_rt: proactive_runtime;
  generation: int;
  trace_id: string;
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
  last_speech_act: string;
  last_blocker: string;
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
  soul_profile: string;
  social_model: string;
  cascade_name: string;
  will: string;
  needs: string;
  desires: string;
  instructions: string;
  policy_voice_enabled: bool;
  execution_scope: string;
  allowed_paths: string list;
  scope_kind: string;
  tool_access: tool_access;
  tool_denylist: string list;
  room_scope: string;
  mention_targets: string list;
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
  continuity_summary: string;
  active_goal_ids: string list;
  active_team_session_id: string option;
  last_team_session_started_at: string;
  team_session_start_count_total: int;
  paused: bool;
  current_task_id: string option;
  (** Currently claimed task ID for cost attribution. *)
  runtime: agent_runtime_state;
}

val default_social_model : string

val now_iso : unit -> string

val tool_access_allowlist : tool_access -> string list
val tool_access_to_json : tool_access -> Yojson.Safe.t

(** {1 Updater helpers for nested record updates} *)

val map_runtime : (agent_runtime_state -> agent_runtime_state) -> keeper_meta -> keeper_meta
val map_usage : (usage_metrics -> usage_metrics) -> keeper_meta -> keeper_meta
val map_compaction_rt : (compaction_runtime -> compaction_runtime) -> keeper_meta -> keeper_meta
val map_proactive_rt : (proactive_runtime -> proactive_runtime) -> keeper_meta -> keeper_meta

(** {1 Legacy model arg rejection} *)

val keeper_legacy_model_arg_names : string list

val reject_legacy_model_args :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result

(** {1 Runtime meta write sync hook} *)

val runtime_meta_write_sync_hook : (Room.config -> keeper_meta -> unit) ref
val register_runtime_meta_write_sync : (Room.config -> keeper_meta -> unit) -> unit

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
val keeper_names : Room.config -> string list
val keepalive_keeper_names : Room.config -> string list
val persistent_agent_names : Room.config -> string list
val fresher_meta : Room.config -> keeper_meta -> keeper_meta
val write_meta : Room.config -> keeper_meta -> (unit, string) result
val read_meta : Room.config -> string -> (keeper_meta option, string) result

(** {1 Re-exports from Keeper_types_support} *)

include module type of Keeper_types_support

(** {1 Fiber health (for keeper supervisor)} *)

type fiber_health =
  | Fiber_alive
  | Fiber_zombie
  | Fiber_dead
  | Fiber_unknown

(** {1 Per-tool usage tracking} *)

type tool_call_entry = {
  mutable count : int;
  mutable successes : int;
  mutable failures : int;
  mutable last_used_at : float;
}
