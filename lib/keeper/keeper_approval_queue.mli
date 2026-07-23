(** Operator-only bulk restart. Non-exact failures return to
    [Summary_not_requested]; released exact failures return to
    [Summary_pending] with [Exact_unbound], permitting a new exact attempt. *)
val restart_failed_summaries :
  base_path:string -> (string list, summary_transition_error) result

val pending_count : unit -> int
val pending_count_for_keeper : keeper_name:string -> int
val has_pending_for_keeper : keeper_name:string -> bool
