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

type stats_result =
  | Default of { reason : string; recommended_ms : int }
  | Adapted of { p95_ms : int; recommended_ms : int; sample_count : int }

val stats : timeout_config -> Bash_history.history_entry list -> stats_result
(** Return detailed statistics for the given entries, indicating whether
    adaptation was possible or a default was used. *)

val stats_to_json : stats_result -> Yojson.Safe.t
(** Serialize stats_result to JSON for telemetry and test assertions. *)

