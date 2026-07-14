type phase =
  Keeper_state_machine_phase.phase =
    Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting
  | Dead
val phase_to_string : Keeper_state_machine_phase.phase -> string
val phase_of_string :
  string -> Keeper_state_machine_phase.phase option
val all_phases : Keeper_state_machine_phase.phase list
type conditions = {
  launch_pending : bool;
  fiber_alive : bool;
  heartbeat_healthy : bool;
  turn_healthy : bool;
  context_within_budget : bool;
  context_handoff_needed : bool;
  compaction_active : bool;
  handoff_active : bool;
  operator_paused : bool;
  stop_requested : bool;
  dead_tombstone_latched : bool;
  restart_requested : bool;
  drain_complete : bool;
  context_overflow : bool;
  credential_archived : bool;
}
val default_conditions : conditions
type context_actions = {
  compact : bool;
  handoff : bool;
}
type event =
    Heartbeat_ok
  | Heartbeat_failed of { consecutive : int; }
  | Turn_succeeded
  | Turn_failed of { consecutive : int; }
  | Context_measured of { context_ratio : float; message_count : int;
      token_count : int; context_actions : context_actions;
    }
  | Compaction_started
  | Compaction_completed of
      { before_checkpoint_bytes : int
      ; after_checkpoint_bytes : int
      }
  | Compaction_failed of { reason : string; }
  | Handoff_started
  | Handoff_completed of { new_trace_id : string; generation : int; }
  | Handoff_failed of { reason : string; }
  | Operator_pause
  | Operator_resume
  | Operator_stop of { remove_meta : bool; }
  | Stop_requested
  | Drain_complete
  | Fiber_started
  | Fiber_terminated of { outcome : string; provider_id : string option;
      http_status : int option;
    }
  | Supervisor_restart_attempt of { attempt : int; }
  | Credential_archived
  | Context_overflow_detected of {
      source : [ `Oas_signal | `Prompt_rejected ]; token_count : int;
      limit_tokens : int option;
    }
  | Auto_compact_triggered
  | Operator_compact_requested
  | Operator_clear_requested of { preserve_system : bool; reason : string; }
val event_to_string : event -> string
type entry_action =
    Start_compaction
  | Start_handoff
  | Start_drain
  | Schedule_restart of { delay_sec : float; }
  | Publish_lifecycle of { event_name : string; detail : string; }
  | Mark_dead_tombstone
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_oas
type transition_result = {
  prev_phase : phase;
  new_phase : phase;
  updated_conditions : conditions;
  entry_actions : entry_action list;
  event_applied : event;
  timestamp : float;
}
type transition_error =
    Terminal_state of { current : phase; attempted_event : string; }
  | Invalid_transition of { from_phase : phase; to_phase : phase;
      reason : string;
    }
  | Precondition_violation of { event : string; reason : string; }
val transition_error_to_string : transition_error -> string
val can_transition : from_phase:phase -> to_phase:phase -> bool
val can_execute_turn : phase -> bool
