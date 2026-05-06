(** Keeper_timing — deterministic timing helpers for turn cycle telemetry. *)

(** Round to 1 decimal place for compact JSON output. *)
let round1 (v : float) : float =
  Float.round (v *. 10.0) /. 10.0

(** [timed f] runs [f ()], returning its result and elapsed time in ms.
    Uses [Time_compat.now] as the single timing source. *)
let timed (f : unit -> 'a) : 'a * float =
  let t0 = Time_compat.now () in
  let result = f () in
  let elapsed_ms = (Time_compat.now () -. t0) *. 1000.0 in
  (result, elapsed_ms)

(** [elapsed_duration_ms ~start_time ~end_time] converts a monotonic time
    interval to an integer millisecond telemetry value. Positive elapsed time
    smaller than 1ms is rounded up so completed calls are not recorded as
    [0ms]. *)
let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000.0 in
  if (not (Float.is_finite elapsed_ms)) || Float.compare elapsed_ms 0.0 <= 0
  then 0
  else max 1 (int_of_float elapsed_ms)
