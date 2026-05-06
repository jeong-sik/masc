(** Keeper_timing — deterministic timing helpers for turn cycle telemetry. *)

(** Round to 1 decimal place for compact JSON output. *)
val round1 : float -> float

(** [timed f] runs [f ()], returning its result and elapsed time in ms.
    Uses [Time_compat.now] as the single timing source. *)
val timed : (unit -> 'a) -> 'a * float

(** Convert elapsed wall-clock timestamps to integer milliseconds for
    telemetry. Positive intervals below 1ms are rounded up to 1 so completed
    calls are not recorded as [0ms]. Non-positive or non-finite intervals
    return 0. *)
val elapsed_duration_ms : start_time:float -> end_time:float -> int
