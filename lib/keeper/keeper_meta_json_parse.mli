(** Keeper meta JSON parser.

    Owns persisted JSON -> [keeper_meta] decoding. Serialization
    stays in [Keeper_meta_json] so canonical-key derivation can
    use the public facade without creating a cycle. *)

open Keeper_types_profile
open Keeper_meta_contract

(** Parsed identity slice of a persisted keeper meta. *)
type parsed_keeper_identity =
  { pk_name : string
  ; pk_agent_name : string
  ; pk_trace_id : Keeper_id.Trace_id.t
  ; pk_trace_history : string list
  ; pk_goal : string
  ; pk_short_goal : string
  ; pk_mid_goal : string
  ; pk_long_goal : string
  ; pk_social_model : string
  ; pk_cascade_name : string
  ; pk_models : string list
  ; pk_will : string
  ; pk_needs : string
  ; pk_desires : string
  ; pk_instructions : string
  }

(** Parsed policy slice of a persisted keeper meta. *)
type parsed_keeper_policy =
  { pp_policy_voice_enabled : bool
  ; pp_sandbox_profile : sandbox_profile
  ; pp_sandbox_image : string option
  ; pp_network_mode : network_mode
  ; pp_allowed_paths : string list
  ; pp_tool_access : tool_access
  ; pp_tool_denylist : string list
  ; pp_mention_targets : string list
  ; pp_room_signal_prompt_enabled : bool
  ; pp_joined_room_ids : string list
  ; pp_last_seen_seq_by_room : (string * int) list
  ; pp_proactive : proactive_policy
  ; pp_compaction : compaction_policy
  ; pp_auto_handoff : bool
  ; pp_handoff_threshold : float
  ; pp_handoff_cooldown_sec : int
  ; pp_voice_enabled : bool
  ; pp_voice_channel : string
  ; pp_voice_agent_id : string
  ; pp_per_provider_timeout_s : float option
  ; pp_always_approve : bool option
  }

(** Parsed runtime/state slice. The [ps_runtime] field threads the
    fully resolved [agent_runtime_state] through. *)
type parsed_keeper_state =
  { ps_created_at_raw : string
  ; ps_updated_at_raw : string
  ; ps_continuity_summary : string
  ; ps_active_goal_ids : string list
  ; ps_paused : bool
  ; ps_autoboot_enabled : bool
  ; ps_current_task_id : Keeper_id.Task_id.t option
  ; ps_max_context_override : int option
  ; ps_runtime : agent_runtime_state
  }

(** Parse the identity slice; rejects missing/invalid trace_id with
    [Error] carrying a contextualized message. *)
val parse_keeper_identity :
  Yojson.Safe.t -> (parsed_keeper_identity, string) result

(** Parse the policy slice. [keeper_name] selects per-keeper
    voice-enabled defaults. *)
val parse_keeper_policy :
  Yojson.Safe.t ->
  keeper_name:string ->
  (parsed_keeper_policy, string) result

(** Parse the runtime usage_metrics record. *)
val parse_usage_metrics : Yojson.Safe.t -> usage_metrics

(** Parse the runtime compaction_runtime record. *)
val parse_compaction_runtime : Yojson.Safe.t -> compaction_runtime

(** Parse the runtime proactive_runtime record. *)
val parse_proactive_runtime : Yojson.Safe.t -> proactive_runtime

(** Heal [last_continuity_update_ts] when the persisted timestamp
    is zero but [continuity_summary] is non-empty (legacy data). *)
val parse_last_continuity_update_ts :
  continuity_summary:string -> Yojson.Safe.t -> float

(** Parse the keeper state slice. [trace_id] / [trace_history]
    are threaded from the identity step. *)
val parse_keeper_state :
  Yojson.Safe.t ->
  trace_id:Keeper_id.Trace_id.t ->
  trace_history:string list ->
  parsed_keeper_state

(** Top-level parser: project a persisted JSON document to a
    fully populated [keeper_meta]. *)
val meta_of_json : Yojson.Safe.t -> (keeper_meta, string) result
