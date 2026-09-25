(** What providers say about their own usage windows, kept for operators.

    Claude Code's [rate_limit_event] and the Codex app-server's
    [account/rateLimits/updated] report, during a turn, how much of each
    usage window the account has used and when the window resets.  The
    Codex app-server also answers [account/rateLimits/read] without a turn,
    and four HTTP providers answer a usage endpoint without a model call
    ({!Runtime_provider_usage_read}).  This module decodes those reports at
    the wire and keeps the latest one per quota scope and window, with the
    time MASC heard it.

    It is an observation.  Routing, candidate ordering, admission and retry
    do not read this table (a spent window read after an HTTP 403 rests its
    scope through {!Runtime_provider_usage_read.read_after_account_refusal},
    on {!Runtime_quota_window}, not here): codex-cli 0.156.0's protocol schema says clients must not
    infer recovery from percentages or reset times, so no availability is
    derived from these numbers.  What the provider said is stored and shown
    as it was said.

    The table is process-local and is not persisted.  A scope with no report
    since this process started is {!Not_reported_since_start}, never an empty
    or zero window.  There is no TTL and no sweeper: a report whose
    [resets_at] has passed stays until a newer report replaces it. *)

type window_kind =
  | Five_hour
  | Seven_day
  | Duration_minutes of int
      (** Codex stated a window length that has no name here. *)
  | Provider_label of string
      (** The provider named the window with a label that has no name here
          (a Claude [unifiedWindows] key), or Codex reported a slot
          ([primary]/[secondary]) without a length. *)

type utilization =
  | Fraction of float  (** Claude Code: [0.67] is 67 %. Not clamped. *)
  | Percent of int  (** Codex [usedPercent]. Not clamped. *)

type source =
  | Claude_code_rate_limit_event
  | Codex_account_rate_limits_updated
  | Codex_account_rate_limits_read
  | Openrouter_key_read  (** OpenRouter [GET /api/v1/key]. *)
  | Zai_quota_limit_read  (** Z.AI [GET /api/monitor/usage/quota/limit]. *)
  | Kimi_coding_usages_read  (** Kimi [GET /coding/v1/usages]. *)
  | Ollama_usage_read  (** Ollama [GET https://ollama.com/api/usage]. *)

type window =
  { limit_id : string option
        (** Codex [limitId]; one account reports several limits.  Claude Code
            names none. *)
  ; kind : window_kind
  ; utilization : utilization
  ; resets_at : int option  (** Unix epoch seconds, as reported. *)
  }

type report =
  { source : source
  ; windows : window list
  }

type decode_error =
  | Expected_object of { path : string }
  | Missing_field of { path : string }
  | Wrong_type of
      { path : string
      ; expected : string
      }
  | Unexpected_value of
      { path : string
      ; expected : string
      }
      (** The field has the right type and a value this decoder does not
          read, e.g. a limit of 0 or a time unit other than minutes. *)
  | Not_successful of
      { path : string
      ; message : string option
      }
      (** The response says it failed ([success] false), with its [msg]. *)
  | Duplicate_window of
      { path : string
      ; limit_id : string option
      ; kind : window_kind
      }
      (** An HTTP usage report states two windows with the same
          [(limit_id, kind)], the key {!record} keeps one row under. *)

val decode_error_to_string : decode_error -> string
val source_to_string : source -> string

val decode_claude_rate_limit_event : Yojson.Safe.t -> (report, decode_error) result
(** A whole stream-json [rate_limit_event] message.  Windows come from
    [rate_limit_info.unifiedWindows]; an event without that member reports no
    windows.  Keys [five_hour] and [seven_day] are {!Five_hour} and
    {!Seven_day}; any other key is kept as {!Provider_label}. *)

val decode_codex_rate_limits_updated : Yojson.Safe.t -> (report, decode_error) result
(** The [params] of an [account/rateLimits/updated] notification.  A null or
    absent [primary]/[secondary] means "no value in this update" and yields no
    window, so the window already recorded stands.  [windowDurationMins] of
    exactly 300 is {!Five_hour} and exactly 10080 is {!Seven_day}; another
    length is {!Duration_minutes}; no length keeps the slot name as
    {!Provider_label}. *)

val decode_codex_rate_limits_read : Yojson.Safe.t -> (report, decode_error) result
(** The result of an [account/rateLimits/read] request, which the app-server
    answers without a thread or a turn. Every bucket of [rateLimitsByLimitId]
    is read, a bucket without its own [limitId] taking its key; when that map
    is absent or null, the single [rateLimits] is read. Windows are decoded as
    in {!decode_codex_rate_limits_updated}. *)

val decode_openrouter_key : Yojson.Safe.t -> (report, decode_error) result
(** OpenRouter [GET /api/v1/key].  A numeric [data.limit] above 0 gives one
    {!Provider_label} window "credit limit" used by
    [(limit - limit_remaining) / limit], with [limit_remaining] within
    [0..limit]; a null [limit] means no cap and no window.  [limit_reset] is
    not read.  [data.free_model_daily_requests] gives "free model requests,
    daily" as [used / limit], with [used] within [0..limit].  Neither states
    a reset time.

    Each HTTP decoder below refuses a report that states the same
    [(limit_id, kind)] twice ({!Duplicate_window}), and a value outside its
    stated range with {!Unexpected_value}. *)

val decode_zai_quota_limit : Yojson.Safe.t -> (report, decode_error) result
(** Z.AI [GET /api/monitor/usage/quota/limit].  [success] must be [true].
    Each [data.limits[]] row is one window with [limit_id] its [type],
    {!Percent} its [percentage] (within [0..100]) and [resets_at] its
    [nextResetTime] in seconds.  [number] must be above 0.  [unit] 3 is
    hours, so [number] hours is mapped like a Codex
    length; any other unit keeps "<type>, <number> x unit <unit>". *)

val decode_kimi_coding_usages : Yojson.Safe.t -> (report, decode_error) result
(** Kimi [GET /coding/v1/usages].  Each [limits[]] row is one window whose
    [window.timeUnit] must be [TIME_UNIT_MINUTE] and [window.duration]
    above 0; its length maps like a Codex length.  [detail.used] and
    [detail.limit] are decimal strings read as integers, [used] within
    [0..limit].  The top-level [usage] is one more window labelled
    "plan period".  [usages.*.used_ratio] is not read. *)

val decode_ollama_usage : Yojson.Safe.t -> (report, decode_error) result
(** Ollama [GET https://ollama.com/api/usage].  [limits] is required;
    [limits.session.usage] is a {!Provider_label} "session" window and
    [limits.weekly.usage] a {!Seven_day} window, each a {!Fraction} that
    must be within [0..1].  No
    reset time is stated. *)

type recorded =
  { window : window
  ; source : source
  ; observed_at : float
  }

type scope_state =
  | Not_reported_since_start
  | Reported of recorded * recorded list

val recording_since : float
(** When this process's table was created (module initialisation, i.e.
    process start).  Every {!Not_reported_since_start} means "nothing heard
    since this time". *)

val record : scope:Runtime_quota_window.scope -> observed_at:float -> report -> unit
(** Keep each window of [report] as the latest for
    [(scope, limit_id, kind)].  An older [observed_at] than the one held does
    not replace it.  A report with no windows changes nothing. *)

val state : scope:Runtime_quota_window.scope -> scope_state
(** The windows held for [scope], ordered by limit then kind. *)

val recorded_scopes : unit -> Runtime_quota_window.scope list
(** Every scope with at least one window, so a projection can show a scope
    that is no longer configured but did report. *)
