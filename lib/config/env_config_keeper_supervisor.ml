(** Keeper supervisor runtime configuration. *)

open Env_config_core

(** Historical keeper Domain_pool pilot flag.

    The supervisor still reads this for observability, but keepalive
    fibers remain on the owning Eio domain. The keepalive body touches
    Eio switches, clocks, turn timeouts, and provider streams; routing
    the whole body through [Domain_pool.submit_io] is not domain-safe. *)
let domain_pool_enabled =
  Feature_flag_registry.get_bool "MASC_KEEPER_DOMAIN_POOL_ENABLED"
;;

(** Interval between supervisor sweep runs (seconds).
    @category Timeouts @ops_class operator *)
let sweep_interval_sec = get_float ~default:30.0 "MASC_KEEPER_SUPERVISOR_SWEEP_SEC"

(** Dead tombstone TTL: seconds before Dead entries are cleaned up.
    @category Timeouts @ops_class operator *)
let dead_ttl_sec = Float.max 60.0 (get_float ~default:3600.0 "MASC_KEEPER_DEAD_TTL_SEC")
