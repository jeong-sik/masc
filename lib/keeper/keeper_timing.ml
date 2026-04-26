(** Keeper_timing — deterministic timing helpers for turn cycle telemetry. *)

(** Round to 1 decimal place for compact JSON output. *)
let round1 (v : float) : float = Float.round (v *. 10.0) /. 10.0

(** [timed f] runs [f ()], returning its result and elapsed time in ms.
    Uses [Time_compat.now] as the single timing source. *)
let timed (f : unit -> 'a) : 'a * float =
  let t0 = Time_compat.now () in
  let result = f () in
  let elapsed_ms = (Time_compat.now () -. t0) *. 1000.0 in
  result, elapsed_ms
;;
