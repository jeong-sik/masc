(** Time constants — SSOT for commonly used durations.

    All values are in seconds (float) unless suffixed with [_int]. The
    module exists to eliminate magic numbers like [86400.0] / [3600.0]
    scattered across the codebase.

    @since 0.4.0 *)

val minute : float
(** Seconds in one minute. *)

val hour : float
(** Seconds in one hour. *)

val day : float
(** Seconds in one day (24 h). *)

val day_int : int
(** Integer seconds in one day. *)

val days_to_seconds : int -> float
(** [days_to_seconds n] returns [float_of_int n *. day]. *)
