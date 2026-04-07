(** Keeper_timing — deterministic timing helpers for turn cycle telemetry. *)

(** Round to 1 decimal place for compact JSON output. *)
let round1 (v : float) : float =
  Float.round (v *. 10.0) /. 10.0
