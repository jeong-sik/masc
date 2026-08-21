(** Keeper supervisor runtime configuration. *)

open Env_config_core

(** Interval between supervisor sweep runs (seconds).
    @category Timeouts @ops_class operator *)
let sweep_interval_sec = get_float ~default:30.0 "MASC_KEEPER_SUPERVISOR_SWEEP_SEC"
