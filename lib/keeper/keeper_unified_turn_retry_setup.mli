(** RFC-0136 PR-4-a: outer setup record for [keeper_unified_turn] retry loop.

    Groups the wall-clock / budget / profile bindings that the retry loop and
    [do_run] closure both observe. *)

type retry_setup =
  { timeout_sec : float
  ; turn_started_at : float
  ; remaining_turn_budget_s : unit -> float
  ; elapsed_ms : float -> int
  ; current_turn_phase_elapsed_ms : float option -> int * int option
  }

(** [build ~now] computes the wall-clock values observed by a turn attempt.

    [now ()] returns the monotonic clock time (in seconds) supplied by the
    Eio clock at the dispatch site.  The retry loop reads it repeatedly via
    [remaining_turn_budget_s] and [current_turn_phase_elapsed_ms]. *)
val build : now:(unit -> float) -> retry_setup
