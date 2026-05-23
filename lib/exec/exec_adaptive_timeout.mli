(** P18: Adaptive Timeout

    Computes per-command timeouts from execution history using p95
    estimation.  New commands get the default; well-known commands get
    a dynamically adjusted timeout based on observed execution times. *)

type timeout_config = {
  default_ms : int;     (** Fallback for unseen commands.  120 000 ms. *)
  min_ms : int;         (** Floor for any timeout.  30 000 ms. *)
  max_ms : int;         (** Ceiling for any timeout.  600 000 ms. *)
  multiplier : float;   (** Safety factor applied to p95.  1.5. *)
  min_samples : int;    (** Minimum successful runs before adapting.  3. *)
}

val default_config : timeout_config

val compute :
  timeout_config ->
  Bash_history.history_entry list ->
  int
(** Compute a recommended timeout in milliseconds from a set of history
    entries.  Only [success = true] entries contribute to the p95 estimate.
    Returns [default_ms] when fewer than [min_samples] successful runs
    are available. *)

