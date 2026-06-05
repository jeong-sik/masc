(** Typed sub-classes for the keeper registry stale-watchdog kill +
    the [Ambiguous_partial_commit] failure-reason payload. *)

type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit =
  { kind : ambiguous_partial_commit_kind
  ; detail : string
  }

type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
  | In_turn_hung of
      { active_seconds : float
      ; timeout_threshold : float
      }
  | Mid_turn_no_progress of
      { active_seconds : float
      ; since_progress_seconds : float
      ; progress_timeout_threshold : float
      ; last_progress_kind : string option
      }
  | Noop_failure_loop of { noop_count : int }

val progress_kind_label : string option -> string
val stale_kill_class_to_string : stale_kill_class -> string
val ambiguous_partial_commit_kind_to_string : ambiguous_partial_commit_kind -> string
