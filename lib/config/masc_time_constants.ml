(** Time constants — SSOT for commonly used durations.

    Eliminates magic numbers like [86400.0] and [3600.0] scattered across
    the codebase.  All values are in seconds (float) unless suffixed with
    [_int].

    @since 2.XXX.0 *)

(** Seconds in one minute. *)
let minute = 60.0

(** Seconds in one hour. *)
let hour = 3600.0

(** Seconds in one day (24 h). *)
let day = 86400.0

(** Integer seconds in one day. *)
let day_int = 86400

(** Convert a day count to seconds. [days_to_seconds 7] = [604800.0]. *)
let days_to_seconds n = float_of_int n *. day
