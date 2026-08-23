(** Pure state transition core for one Keeper owner.

    This module contains no locks, fibers, persistence calls, clocks, or
    callbacks.  Metadata changes are a closed command set: callers cannot
    submit an arbitrary [keeper_meta -> keeper_meta] function. *)

type usage_delta =
  { turns : int
  ; input_tokens : int
  ; output_tokens : int
  ; total_tokens : int
  ; cost_usd : float
  ; last_turn_ts : float
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_usage_reported_at : float option
  ; last_latency_ms : int
  }

type turn_counter_deltas =
  { proactive_count : int
  ; proactive_visible_count : int
  ; autonomous_action_count : int
  ; autonomous_turn_count : int
  ; autonomous_text_turn_count : int
  ; autonomous_tool_turn_count : int
  ; board_reactive_turn_count : int
  ; mention_reactive_turn_count : int
  ; noop_turn_count : int
  ; compaction_count : int
  }

type 'a observed_change =
  | Unchanged
  | Changed of 'a

type turn_runtime_delta =
  { expected_trace_id : Keeper_id.Trace_id.t
  ; usage : usage_delta
  ; counters : turn_counter_deltas
  ; next_keeper_id : Keeper_id.Uid.t option
  ; next_agent_name : string
  ; next_trace_id : Keeper_id.Trace_id.t
  ; next_trace_history : string list
  ; next_generation : int
  ; next_last_handoff_ts : float
  ; compaction_observation : Keeper_meta_contract.compaction_runtime observed_change
  ; proactive_observation : Keeper_meta_contract.proactive_runtime observed_change
  ; last_autonomous_action_at : string observed_change
  ; last_blocker : Keeper_meta_contract.blocker_info option observed_change
  ; message_scope_ack_id : string option observed_change
  ; updated_at : string
  }

type identity_handoff =
  { keeper_id : Keeper_id.Uid.t option
  ; agent_name : string
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; updated_at : string
  }

type shutdown_latch = Operator_stopped

type profile_update =
  { instructions : string
  ; autonomous_instructions : string option
  ; sandbox_profile : Keeper_types_profile.sandbox_profile
  ; sandbox_image : string option
  ; network_mode : Keeper_types_profile.network_mode
  ; allowed_paths : string list
  ; mention_targets : string list
  ; proactive_enabled : bool
  ; max_context_override : int option
  ; autoboot_enabled : bool
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; always_allow : bool option
  ; agent_core_env : (string * string) list
  ; updated_at : string
  }

type meta_command =
  | Create of Keeper_meta_contract.keeper_meta
  | Pause of
      { reason : Keeper_latched_reason.t
      ; updated_at : string
      }
  | Resume of { updated_at : string }
  | Reset_latch of { updated_at : string }
  | Retain_shutdown_latch of
      { latch : shutdown_latch
      ; updated_at : string
      }
  | Set_autoboot of
      { enabled : bool
      ; updated_at : string
      }
  | Update_profile of profile_update
  | Handoff_identity of identity_handoff
  | Repair_trace_generation of
      { trace_id : Keeper_id.Trace_id.t
      ; trace_history : string list
      ; updated_at : string
      }
  | Delete_if_snapshot of Keeper_meta_json.Snapshot_digest.t
  | Turn_started_projection of { updated_at : string }
  | Turn_succeeded of
      { usage : usage_delta
      ; updated_at : string
      }
  | Turn_failed of
      { blocker : Keeper_meta_contract.blocker_info
      ; usage : usage_delta option
      ; updated_at : string
      }
  | Commit_turn_runtime of turn_runtime_delta
  | Add_usage of usage_delta
  | Set_current_task of
      { task_id : Keeper_id.Task_id.t option
      ; updated_at : string
      }
  | Set_blocker of
      { blocker : Keeper_meta_contract.blocker_info option
      ; updated_at : string
      }
  | Record_compaction_commit of
      { trace_id : Keeper_id.Trace_id.t
      ; commit_count : int
      ; at : float
      ; before_bytes : int
      ; after_bytes : int
      ; updated_at : string
      }
  | Ack_message_scope of
      { message_id : string option
      ; updated_at : string
      }

type state

type projection =
  { meta : Keeper_meta_contract.keeper_meta option
  ; stopping : bool
  }

type persistence_intent =
  | No_persistence
  | Replace_snapshot of Keeper_meta_contract.keeper_meta
  | Remove_snapshot of Keeper_meta_contract.keeper_meta

type transition =
  { state : state
  ; persistence : persistence_intent
  ; projection : projection
  }

type error =
  | Meta_missing
  | Meta_already_exists
  | Owner_stopping
  | Invalid_delta of string
  | Keeper_identity_mismatch of
      { expected : string
      ; actual : string
      }
  | Identity_mismatch
  | Snapshot_changed

val turn_runtime_delta_of_snapshots
  :  before:Keeper_meta_contract.keeper_meta
  -> after:Keeper_meta_contract.keeper_meta
  -> (turn_runtime_delta, error) result

val create
  :  keeper_name:string
  -> Keeper_meta_contract.keeper_meta option
  -> (state, error) result
val projection : state -> projection
val apply_meta : state -> meta_command -> (transition, error) result

val begin_stopping : state -> transition
val error_to_string : error -> string
