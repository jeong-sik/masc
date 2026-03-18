(** Mitosis Prometheus Metrics.

    Registers and exposes counters, gauges, and histograms for the
    mitosis (cell-division) subsystem. All helpers are thin wrappers
    around {!Prometheus} so callers need not know metric names.

    Metrics are auto-created on first use (Prometheus auto-vivifies
    unknown keys) so no Eio runtime is needed at module load time.

    {2 Metric inventory}

    {v
      mitosis_handoff_total              counter    Successful handoffs
      mitosis_prepare_total              counter    DNA preparations
      mitosis_error_total                counter    Errors (labeled by reason)
      mitosis_current_generation         gauge      Current generation number
      mitosis_cooldown_remaining_seconds gauge      Seconds until next handoff allowed
      mitosis_handoff_duration_seconds   histogram  Handoff execution duration
    v}

    @since 0.5.0 *)

(** {1 Metric Names} *)

(** Prometheus metric name for total successful handoffs. *)
val handoff_total : string

(** Prometheus metric name for total DNA preparations. *)
val prepare_total : string

(** Prometheus metric name for total errors (supports [reason] label). *)
val error_total : string

(** Prometheus metric name for the current generation gauge. *)
val current_generation : string

(** Prometheus metric name for the cooldown remaining gauge. *)
val cooldown_remaining : string

(** Prometheus metric name for the handoff duration histogram. *)
val handoff_duration : string

(** {1 Convenience Helpers} *)

(** [inc_handoff ()] increments the [mitosis_handoff_total] counter by 1. *)
val inc_handoff : unit -> unit

(** [inc_prepare ()] increments the [mitosis_prepare_total] counter by 1. *)
val inc_prepare : unit -> unit

(** [inc_error ?reason ()] increments the [mitosis_error_total] counter by 1.

    @param reason optional label value describing the error cause.
      Defaults to ["unknown"]. *)
val inc_error : ?reason:string -> unit -> unit

(** [set_generation gen] sets the [mitosis_current_generation] gauge
    to [gen] (converted to float). *)
val set_generation : int -> unit

(** [set_cooldown_remaining secs] sets the
    [mitosis_cooldown_remaining_seconds] gauge to [secs]. *)
val set_cooldown_remaining : float -> unit

(** [observe_handoff_duration secs] records a handoff duration observation
    in the [mitosis_handoff_duration_seconds] histogram. *)
val observe_handoff_duration : float -> unit
