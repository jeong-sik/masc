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

type identity_handoff =
  { keeper_id : Keeper_id.Uid.t option
  ; agent_name : string
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; generation : int
  ; updated_at : string
  }

type compaction_result =
  { count_delta : int
  ; at : float
  ; before_tokens : int
  ; after_tokens : int
  ; checked_at : float
  ; decision : Keeper_meta_contract.compaction_runtime_decision
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
  | Set_autoboot of
      { enabled : bool
      ; updated_at : string
      }
  | Handoff_identity of identity_handoff
  | Repair_trace_generation of
      { trace_id : Keeper_id.Trace_id.t
      ; trace_history : string list
      ; generation : int
      ; updated_at : string
      }
  | Delete
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
  | Add_usage of usage_delta
  | Set_current_task of
      { task_id : Keeper_id.Task_id.t option
      ; updated_at : string
      }
  | Set_blocker of
      { blocker : Keeper_meta_contract.blocker_info option
      ; updated_at : string
      }
  | Record_compaction of compaction_result
  | Ack_message_scope of
      { message_id : string option
      ; updated_at : string
      }

type state

type projection =
  { meta : Keeper_meta_contract.keeper_meta option
  ; running_operation_id : string option
  ; stopping : bool
  }

type persistence_intent =
  | No_persistence
  | Replace_snapshot of Keeper_meta_contract.keeper_meta
  | Remove_snapshot of Keeper_meta_contract.keeper_meta

type post_commit_effect =
  | Publish_projection of projection
  | Start_turn_child of { operation_id : string }

type transition =
  { state : state
  ; persistence : persistence_intent
  ; effects : post_commit_effect list
  }

type error =
  | Meta_missing
  | Meta_already_exists
  | Owner_stopping
  | Turn_already_running of string
  | Turn_not_running
  | Turn_identity_mismatch of
      { expected : string
      ; actual : string
      }
  | Invalid_delta of string

val create : Keeper_meta_contract.keeper_meta option -> state
val projection : state -> projection
val apply_meta : state -> meta_command -> (transition, error) result

val begin_turn
  :  state
  -> operation_id:string
  -> (transition, error) result

val finish_turn
  :  state
  -> operation_id:string
  -> (transition, error) result

val begin_stopping : state -> transition
val error_to_string : error -> string
