(** Env-driven runtime configuration for tier admission backoff.

    When a cascade tier reports [Capacity_full], the admission
    path may optionally retry after a short delay with exponential
    backoff + full jitter (Marc Brooker strategy), rather than
    immediately advancing to the next tier.

    All knobs are env-overridable for live tuning without redeploy.

    @since RFC-0153 Phase B.2 — task-503 *)

let read_float_setting ~primary ~default () =
  match Sys.getenv_opt primary with
  | Some s -> (try float_of_string s with _ -> default)
  | None -> default

let read_int_setting ~primary ~default () =
  match Sys.getenv_opt primary with
  | Some s -> (try int_of_string s with _ -> default)
  | None -> default

let read_bool_setting ~primary ~default () =
  match Sys.getenv_opt primary with
  | Some s ->
      let s = String.lowercase_ascii (String.trim s) in
      s = "true" || s = "1" || s = "yes" || s = "on"
  | None -> default

(** {1 Backoff configuration} *)

(** Enabled by default. Set [MASC_TIER_ADMISSION_BACKOFF_ENABLED=false] to
    disable; the admission path reverts to the original non-blocking
    behaviour (immediate [Capacity_full] error, no retry). *)
let enabled () =
  read_bool_setting
    ~primary:"MASC_TIER_ADMISSION_BACKOFF_ENABLED"
    ~default:true
    ()

(** Base delay in seconds for the first retry attempt. Default 0.25s —
    short enough to avoid visible latency, long enough to let a slot
    free up under normal contention. *)
let base_delay_sec () =
  read_float_setting
    ~primary:"MASC_TIER_ADMISSION_BACKOFF_BASE_DELAY_SEC"
    ~default:0.25
    ()

(** Maximum delay cap in seconds. Prevents unbounded growth of
    exponential backoff. Default 8.0s — if the tier stays saturated
    for 8s the caller should advance rather than wait longer. *)
let max_delay_sec () =
  read_float_setting
    ~primary:"MASC_TIER_ADMISSION_BACKOFF_MAX_DELAY_SEC"
    ~default:8.0
    ()

(** Maximum number of retry attempts before giving up and returning
    [Capacity_full]. Default 3 — gives the tier ~1-2s of total wait
    time before the cascade advances. *)
let max_retries () =
  read_int_setting
    ~primary:"MASC_TIER_ADMISSION_BACKOFF_MAX_RETRIES"
    ~default:3
    ()

(** Exponential base. Each retry multiplies the effective cap by this
    factor before jitter. Default 2.0 (standard exponential). *)
let exponential_base () =
  read_float_setting
    ~primary:"MASC_TIER_ADMISSION_BACKOFF_EXPONENTIAL_BASE"
    ~default:2.0
    ()

type t = {
  enabled : bool;
  base_delay_sec : float;
  max_delay_sec : float;
  max_retries : int;
  exponential_base : float;
}

let from_env () : t =
  {
    enabled = enabled ();
    base_delay_sec = base_delay_sec ();
    max_delay_sec = max_delay_sec ();
    max_retries = max_retries ();
    exponential_base = exponential_base ();
  }