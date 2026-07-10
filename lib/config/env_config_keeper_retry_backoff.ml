(** Keeper transient-retry backoff configuration.

    Exponential backoff knobs for the keeper outer-loop transient
    retry path plus the productive slot-phase budget gate used by
    [Keeper_turn_runtime_budget] when deciding whether a degraded
    retry rotation may proceed.

    Verbatim extract from [Env_config_keeper.KeeperRetryBackoff];
    the parent now does
    [module KeeperRetryBackoff = Env_config_keeper_retry_backoff]
    and existing call sites resolve through the parent module alias
    unchanged. *)

open Env_config_core

(** Maximum outer-loop retries after the initial attempt.
    Total attempts = 1 initial + max_transient_retries.
    Env: [MASC_KEEPER_MAX_TRANSIENT_RETRIES].  Default: 2. *)
let max_transient_retries () = get_int ~default:2 "MASC_KEEPER_MAX_TRANSIENT_RETRIES"

(** Base delay (seconds) for exponential backoff.
    Delay at attempt [n] is [base * 2^(n-1)].
    Env: [MASC_KEEPER_TRANSIENT_BACKOFF_BASE_SEC].  Default: 1.0. *)
let transient_backoff_base_sec () =
  get_float ~default:1.0 "MASC_KEEPER_TRANSIENT_BACKOFF_BASE_SEC"
;;

(** Hard cap on backoff delay (seconds).
    Env: [MASC_KEEPER_TRANSIENT_BACKOFF_CAP_SEC].  Default: 4.0. *)
let transient_backoff_cap_sec () =
  get_float ~default:4.0 "MASC_KEEPER_TRANSIENT_BACKOFF_CAP_SEC"
;;

(** Exponential backoff delay for transient retry [attempt] (1-indexed).
    Env: [MASC_KEEPER_TRANSIENT_BACKOFF_BASE_SEC] and
    [MASC_KEEPER_TRANSIENT_BACKOFF_CAP_SEC]. *)
let transient_backoff_sec (attempt : int) : float =
  let base = transient_backoff_base_sec () in
  let cap = transient_backoff_cap_sec () in
  let rec grow remaining delay =
    if remaining <= 0 || delay >= cap
    then Float.min cap delay
    else grow (remaining - 1) (Float.min cap (delay *. 2.0))
  in
  grow (max 0 (attempt - 1)) base
;;

(** Productive retry-phase budget (seconds).  PR #13120: when a
    runtime returns a recoverable error after the keeper has
    already burned this many seconds inside the current holder,
    degraded retry rotation is rejected (the rotation evidence is
    still recorded in [runtime_rotation_attempts] for audit).  The
    keeper releases the outer holder instead of holding it for a
    retry that may itself stall.  OAS timeout-budget failures may
    still rotate to the next degraded runtime when retry budget remains,
    because the first attempt already consumed its bounded provider
    budget.  Floor 5s prevents accidental always-reject configs.

    Declared here (not in keeper_turn_runtime_budget.ml) so the
    env knob catalog generator at bin/env_knob_catalog.ml picks
    it up — the catalog only scans lib/config/env_config_*.ml.

    Env: [MASC_KEEPER_DEGRADED_RETRY_SLOT_PHASE_BUDGET_SEC].
    Default: 180.0.
    @category Timeouts
    @ops_class operator

    Calibrated to the attempt-liveness bootstrap floor so that
    slow-but-honest streams are not denied a degraded retry solely
    because their first-token latency exceeds the old 60 s floor.
    Providers with successful history can learn a wider candidate
    budget without hard-coding provider or model-size classes. *)
let degraded_retry_slot_phase_budget_sec =
  Float.max
    5.0
    (get_float ~default:180.0 "MASC_KEEPER_DEGRADED_RETRY_SLOT_PHASE_BUDGET_SEC")
;;
