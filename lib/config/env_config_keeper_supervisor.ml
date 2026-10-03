(** Keeper supervisor runtime configuration. *)

open Env_config_core

(** Interval between supervisor sweep runs (seconds).
    @category Timeouts @ops_class operator *)
let sweep_interval_default_sec = 30.0
let sweep_interval_min_sec = 10.0
let sweep_interval_max_sec = 120.0

let sweep_interval_sec () =
  let value = get_float_nonneg ~default:sweep_interval_default_sec
      "MASC_KEEPER_SUPERVISOR_SWEEP_SEC" in
  Float.max sweep_interval_min_sec (Float.min sweep_interval_max_sec value)
