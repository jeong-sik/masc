(** RFC-0136 PR-4-a: elapsed-time observation for runtime rotation.

    The values feed receipts and telemetry only; they do not admit, reject,
    pause, or terminate a Keeper turn. *)

type retry_setup =
  { current_turn_phase_elapsed_ms : float option -> int * int option
  }

(** [build ~now] computes the wall-clock values observed by a turn attempt.

    [now ()] returns the monotonic clock time (in seconds) supplied by the
    Eio clock at the dispatch site. The retry loop reads it only to observe
    productive and retry-phase elapsed time. *)
val build : now:(unit -> float) -> retry_setup
