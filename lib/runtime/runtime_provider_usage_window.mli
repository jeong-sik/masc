(** What providers say about their own usage windows, kept for operators.

    Claude Code's [rate_limit_event] and the Codex app-server's
    [account/rateLimits/updated] report, during a turn, how much of each
    usage window the account has used and when the window resets.  This
    module decodes those reports at the wire and keeps the latest one per
    quota scope and window, with the time MASC heard it.

    It is an observation.  Routing, candidate ordering, admission and retry
    do not read it: codex-cli 0.156.0's protocol schema says clients must not
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
