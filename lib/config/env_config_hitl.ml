open Env_config_core

(** HITL (human-in-the-loop) approval configuration.

    Bounded timeouts prevent dangerous tool approvals from stalling a Keeper
    turn indefinitely while still giving operators a reasonable decision
    window.

    @category Timeouts
    @ops_class operator *)

let default_critical_timeout_s = 3600.0

let critical_timeout_s_value =
  let raw =
    get_float
      ~default:default_critical_timeout_s
      "MASC_HITL_CRITICAL_TIMEOUT_S"
  in
  if not (Float.is_finite raw)
  then (
    Log.Misc.warn
      "MASC_HITL_CRITICAL_TIMEOUT_S=%g is non-finite; using default %.2f"
      raw
      default_critical_timeout_s;
    default_critical_timeout_s)
  else if raw <= 0.0
  then (
    Log.Misc.warn
      "MASC_HITL_CRITICAL_TIMEOUT_S=%.2f disables the critical approval timeout; \
       dangerous tools may stall turns indefinitely (legacy behavior)"
      raw;
    0.0)
  else raw
;;

(** Critical-tool approval timeout in seconds.

    Env: [MASC_HITL_CRITICAL_TIMEOUT_S]. Default: [3600.0] (1 hour).
    Values <= [0.0] disable the timeout and revert to the legacy
    operator-must-decide behavior (warned once at module load). *)
let critical_timeout_s () = critical_timeout_s_value
