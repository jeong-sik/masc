type ambiguous_partial_commit_kind =
  Keeper_registry_types_kill_class.ambiguous_partial_commit_kind =
    Post_commit_timeout
  | Post_commit_failure
type ambiguous_partial_commit =
  Keeper_registry_types_kill_class.ambiguous_partial_commit = {
  kind : ambiguous_partial_commit_kind;
  detail : string;
}
type stale_kill_class =
  Keeper_registry_types_kill_class.stale_kill_class =
    Idle_turn of { stall_seconds : float; }
  | In_turn_hung of { active_seconds : float; timeout_threshold : float; }
  | Mid_turn_no_progress of { active_seconds : float;
      since_progress_seconds : float; progress_timeout_threshold : float;
      last_progress_kind : string option;
    }
  | Noop_failure_loop of { noop_count : int; }
val progress_kind_label : string option -> string
val stale_kill_class_to_string :
  Keeper_registry_types_kill_class.stale_kill_class -> string
type failure_reason =
    Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int; }
  | Stale_fleet_batch of { distinct_count : int; }
  | Provider_timeout_loop of { count : int; }
  | Provider_runtime_error of { code : string; detail : string;
      provider_id : string option; http_status : int option;
      cascade_name : string option;
    }
  | Tool_required_unsatisfied of { code : string; detail : string; }
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string
  | Turn_overflow_pause
  | Turn_livelock_pause
val ambiguous_partial_commit_kind_to_string :
  Keeper_registry_types_kill_class.ambiguous_partial_commit_kind ->
  string
val failure_reason_to_string : failure_reason -> string
val failure_reason_cohort_key : failure_reason option -> string
val stale_watchdog_failure_reason :
  prior:failure_reason option ->
  kill_class:stale_kill_class -> failure_reason option
