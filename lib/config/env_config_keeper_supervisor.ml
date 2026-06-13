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

(** Maximum restart attempts before declaring a keeper dead.
    @category Thresholds @ops_class operator *)
let max_restarts = get_int ~default:5 "MASC_KEEPER_SUPERVISOR_MAX_RESTARTS"

(** Base delay for exponential backoff between restarts (seconds).
    @category Timeouts @ops_class operator *)
let backoff_base_s = get_float ~default:10.0 "MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S"

(** Maximum backoff delay cap (seconds).
    @category Timeouts @ops_class operator *)
let backoff_max_s = get_float ~default:300.0 "MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S"

(** Interval between supervisor sweep runs (seconds).
    @category Timeouts @ops_class operator *)
let sweep_interval_sec = get_float ~default:30.0 "MASC_KEEPER_SUPERVISOR_SWEEP_SEC"

(** Self-preservation: ratio of crashed keepers to trigger suppression.
    @category Thresholds @ops_class operator *)
let self_preservation_ratio =
  Float.min
    1.0
    (Float.max 0.0 (get_float ~default:0.3 "MASC_KEEPER_SELF_PRESERVATION_RATIO"))
;;

(** Self-preservation: minimum crashed candidates to trigger.
    @category Thresholds @ops_class operator *)
let self_preservation_min_candidates =
  max 1 (get_int ~default:2 "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES")
;;

(** Dead tombstone TTL: seconds before Dead entries are cleaned up.
    @category Timeouts @ops_class operator *)
let dead_ttl_sec = Float.max 60.0 (get_float ~default:3600.0 "MASC_KEEPER_DEAD_TTL_SEC")

(** Paused keeper file TTL: seconds before stale paused keeper meta files
    are removed from disk. Default: 86400 (24 hours).
    @category Timeouts @ops_class operator *)
let paused_cleanup_ttl_sec =
  Float.max
    300.0
    (get_float ~default:Masc_time_constants.day "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC")
;;

(** Initial auto-resume backoff delay after an auto-pause (seconds).
    On every successive auto-pause the delay doubles, capped at
    [auto_resume_max_sec].  Default: 3600 (1 hour).
    Set to 0 to disable the self-healing circuit breaker.
    @category Timeouts @ops_class operator *)
let auto_resume_initial_sec =
  Float.max 0.0 (get_float ~default:3600.0 "MASC_KEEPER_AUTO_RESUME_INITIAL_SEC")
;;

(** Maximum auto-resume backoff delay (seconds).  Default: 86400 (24 hours).
    @category Timeouts @ops_class operator *)
let auto_resume_max_sec =
  Float.max 3600.0 (get_float ~default:86400.0 "MASC_KEEPER_AUTO_RESUME_MAX_SEC")
;;
