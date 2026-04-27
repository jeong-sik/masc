(** Keeper_timing — deterministic timing helpers for turn cycle telemetry. *)

(** Round to 1 decimal place for compact JSON output. *)
val round1 : float -> float

(** [timed f] runs [f ()], returning its result and elapsed time in ms.
    Uses [Time_compat.now] as the single timing source. *)
val timed : (unit -> 'a) -> 'a * float
