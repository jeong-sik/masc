(** Typed sub-classes for the keeper registry stale-watchdog kill. *)

type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
  | Mid_turn_no_progress of
      { active_seconds : float
      ; since_progress_seconds : float
      ; progress_timeout_threshold : float
      ; last_progress_kind : string option
      }
  | Noop_failure_loop of { noop_count : int }

val progress_kind_label : string option -> string
val stale_kill_class_to_string : stale_kill_class -> string
