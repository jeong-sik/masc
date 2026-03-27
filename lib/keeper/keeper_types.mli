(** Keeper_types -- shared keeper contract, registry/store helpers,
    path resolution, and model-selection utilities.

    Re-exports everything from {!Keeper_types_profile} (context, schemas,
    profile defaults, path helpers) and {!Keeper_types_resident}
    (model selection, JSONL helpers, metrics store). *)

include module type of Keeper_types_profile

(** {1 Compaction state} *)

type compaction_state = {
  profile: string;
  ratio_gate: float;
  message_gate: int;
  token_gate: int;
  cooldown_sec: int;
  count: int;
  last_ts: float;
  last_before_tokens: int;
  last_after_tokens: int;
  last_check_ts: float;
  last_decision: string;
}

(** {1 Usage metrics} *)

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

(** {1 Proactive config} *)

type proactive_config = {
  enabled: bool;
  idle_sec: int;
  cooldown_sec: int;
  count_total: int;
  last_ts: float;
  last_reason: string;
  last_preview: string;
}

(** {1 Keeper meta} *)

type keeper_meta = {
  name: string;
  agent_name: string;
  trace_id: string;
  trace_history: string list;
  goal: string;
  short_goal: string;
  mid_goal: string;
  long_goal: string;
  soul_profile: string;
  cascade_name: string;
  will: string;
  needs: string;
  desires: string;
  instructions: string;
  policy_voice_enabled: bool;
  execution_scope: string;
  allowed_paths: string list;
  scope_kind: string;
  room_scope: string;
  mention_targets: string list;
  joined_room_ids: string list;
  last_seen_seq_by_room: (string * int) list;
  generation: int;
  presence_keepalive: bool;
  presence_keepalive_sec: int;
  proactive: proactive_config;
  compaction: compaction_state;
  auto_handoff: bool;
  handoff_threshold: float;
  handoff_cooldown_sec: int;
  voice_enabled: bool;
  voice_channel: string;
  voice_agent_id: string;
  last_handoff_ts: float;
  created_at: string;
  updated_at: string;
  usage: usage_metrics;
  last_continuity_update_ts: float;
  continuity_summary: string;
  active_goal_ids: string list;
  active_team_session_id: string option;
  last_team_session_started_at: string;
  team_session_start_count_total: int;
  last_autonomous_action_at: string;
  autonomous_action_count: int;
  autonomous_turn_count: int;
  autonomous_text_turn_count: int;
  autonomous_tool_turn_count: int;
  board_reactive_turn_count: int;
  mention_reactive_turn_count: int;
  noop_turn_count: int;
  last_triage_triggers: string;
  paused: bool;
  current_task_id: string option;
  (** Currently claimed task ID for cost attribution. *)
}

val now_iso : unit -> string

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

(** {1 Keeper boot entry (resident keepers)} *)

type keeper_boot_entry = {
  name : string;
  persona_name : string;
  voice_enabled : bool;
  voice_channel : string;
  voice_agent_id : string;
  created_at : string;
  updated_at : string;
}

val resident_keeper_dir : Room.config -> string
val resident_keeper_path : Room.config -> string -> string
val keeper_boot_to_json : keeper_boot_entry -> Yojson.Safe.t
val keeper_boot_of_json : Yojson.Safe.t -> (keeper_boot_entry, string) result
val keeper_boot_entry_of_meta : ?created_at:string -> keeper_meta -> keeper_boot_entry

val write_resident_keeper : Room.config -> keeper_boot_entry -> (unit, string) result
val read_resident_keeper : Room.config -> string -> (keeper_boot_entry option, string) result
val remove_resident_keeper : Room.config -> string -> unit
val list_resident_keepers : Room.config -> keeper_boot_entry list
val resident_keeper_names : Room.config -> string list
val is_resident_keeper : Room.config -> string -> bool

(** {1 Meta file I/O} *)

val read_meta_file_path : string -> (keeper_meta option, string) result
val register_resident_keeper : Room.config -> string -> (unit, string) result
val persistent_agent_names : ?resident_names:string list -> Room.config -> string list
val sync_registered_resident_keeper : Room.config -> string -> (unit, string) result
val fresher_meta : Room.config -> keeper_meta -> keeper_meta
val write_meta : Room.config -> keeper_meta -> (unit, string) result
val read_meta : Room.config -> string -> (keeper_meta option, string) result

(** {1 Re-exports from Keeper_types_resident} *)

include module type of Keeper_types_resident

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
