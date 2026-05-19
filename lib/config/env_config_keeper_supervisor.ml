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

(** Liveness Recovery Supervisor (#12801): enable auto-recovery of Dead keepers
    whose root cause has cleared.  Set to false to disable (default: true).
    @category Policies @ops_class operator *)
let liveness_recovery_enabled =
  get_bool ~default:true "MASC_KEEPER_LIVENESS_RECOVERY_ENABLED"
;;

(** Minimum time (seconds) a keeper must have been Dead before a liveness
    recovery attempt is made.  Allows transient root causes (e.g. provider
    outage) to clear before re-launching.  Default: 300 (5 min).
    @category Timeouts @ops_class operator *)
let liveness_recovery_min_dead_sec =
  Float.max 30.0 (get_float ~default:300.0 "MASC_KEEPER_LIVENESS_RECOVERY_MIN_DEAD_SEC")
;;

(** Base backoff delay (seconds) between liveness recovery attempts per keeper.
    Exponential: attempt 0 = base, 1 = 2*base, 2 = 4*base, etc.
    Default: 300 (5 min).
    @category Timeouts @ops_class operator *)
let liveness_recovery_backoff_base_sec =
  Float.max
    30.0
    (get_float ~default:300.0 "MASC_KEEPER_LIVENESS_RECOVERY_BACKOFF_BASE_SEC")
;;

(** Maximum backoff delay cap (seconds) for liveness recovery.
    Default: 3600 (1 hour).
    @category Timeouts @ops_class operator *)
let liveness_recovery_backoff_max_sec =
  Float.max
    60.0
    (get_float ~default:3600.0 "MASC_KEEPER_LIVENESS_RECOVERY_BACKOFF_MAX_SEC")
;;

(** Maximum total liveness recovery attempts per keeper before giving up
    permanently.  Default: 5.
    @category Thresholds @ops_class operator *)
let liveness_recovery_max_attempts =
  max 1 (get_int ~default:5 "MASC_KEEPER_LIVENESS_RECOVERY_MAX_ATTEMPTS")
;;

(** Signal for alive-but-stuck keepers (#12838): keepers that are not
    Dead/Zombie and not paused, but whose [proactive_rt.last_ts] has been
    frozen while autonomous turns keep advancing.
    @category Policies @ops_class operator *)
let alive_but_stuck_enabled =
  get_bool ~default:true "MASC_KEEPER_ALIVE_BUT_STUCK_ENABLED"
;;

(** Queue a bounded recovery wakeup when [alive_but_stuck_scan] emits.
    The recovery uses the Event Layer queue plus [fiber_wakeup]; it does
    not restart the keeper or create a board post.  Dedup is still bounded
    by [alive_but_stuck_dedup_ttl_sec].  Default: true.
    @category Policies @ops_class operator *)
let alive_but_stuck_recovery_enabled =
  get_bool ~default:true "MASC_KEEPER_ALIVE_BUT_STUCK_RECOVERY_ENABLED"
;;

(** Multiplier on the keeper's own [proactive.cooldown_sec] before a
    stalled keeper is flagged.  Default: 10 (10 cooldowns elapsed
    without a proactive turn).
    @category Thresholds @ops_class operator *)
let alive_but_stuck_stall_multiplier =
  max 1 (get_int ~default:10 "MASC_KEEPER_ALIVE_BUT_STUCK_STALL_MULTIPLIER")
;;

(** Hard floor (seconds) so keepers with very small cooldowns are not
    flagged after a few minutes of legitimate quiet.  The detector
    uses [max(stall_floor, multiplier * cooldown)].  Default:
    1800 (30 min).
    @category Timeouts @ops_class operator *)
let alive_but_stuck_stall_floor_sec =
  Float.max 60.0 (get_float ~default:1800.0 "MASC_KEEPER_ALIVE_BUT_STUCK_STALL_FLOOR_SEC")
;;

(** Per-keeper dedup window (seconds): once a keeper is flagged the
    counter is incremented at most once per window, even if the
    sweep fires every 30s.  Default: 3600 (1 hr).
    @category Timeouts @ops_class operator *)
let alive_but_stuck_dedup_ttl_sec =
  Float.max 60.0 (get_float ~default:3600.0 "MASC_KEEPER_ALIVE_BUT_STUCK_DEDUP_TTL_SEC")
;;
