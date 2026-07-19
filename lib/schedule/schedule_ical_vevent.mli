(** Schedule_ical_vevent — RFC 5545 VEVENT recurrence identity (leaf 3).

    Projects the recurrence-identity properties of one VEVENT — [UID],
    [DTSTART], [RECURRENCE-ID], [RRULE] — from already-parsed content lines
    ({!Schedule_ical_content_line.t}) into one typed value. Pure and total.
    Non-identity properties ([SUMMARY], [DTEND], x-props, ...) are ignored:
    this module projects identity, not the whole component.

    Enforced cross-property rules (typed errors, no silent coercion):
    - [UID] exactly once, non-empty (§3.8.4.7).
    - [DTSTART] exactly once (§3.8.2.4: REQUIRED for VEVENT).
    - [RECURRENCE-ID] at most once; its value form must match [DTSTART]'s
      (§3.8.4.4), including the TZID reference when present.
    - [RRULE] at most once (§3.8.5.3); when it carries [UNTIL], the UNTIL
      value form must agree with [DTSTART] per §3.3.10: DATE with DATE,
      floating local with local, UTC or TZID-referenced DTSTART with UTC.
    - [RANGE] on [RECURRENCE-ID] is typed ([THISANDPRIOR] default,
      [THISANDFUTURE]); anything else is rejected.

    TZID is carried as a validated opaque identifier; timezone resolution
    (VTIMEZONE/IANA) is a later leaf. *)

module Content_line = Schedule_ical_content_line
module Recur = Schedule_ical_recur

type tzid = private string

type dtstart =
  | Start_date of Recur.date
  | Start_local of Recur.date * Recur.time_of_day
  | Start_utc of Recur.date * Recur.time_of_day
  | Start_tzid of tzid * Recur.date * Recur.time_of_day

type range =
  | This_and_prior  (** RFC default. *)
  | This_and_future

type recurrence_id = private
  { value : dtstart
  ; range : range
  }

type t = private
  { uid : string
  ; dtstart : dtstart
  ; recurrence_id : recurrence_id option
  ; rrule : Recur.t option
  }

type parse_error =
  | Missing_uid
  | Duplicate_uid
  | Empty_uid
  | Missing_dtstart
  | Duplicate_dtstart
  | Invalid_dtstart of { value : string; detail : string }
  | Duplicate_recurrence_id
  | Invalid_recurrence_id of { value : string; detail : string }
  | Recurrence_id_value_mismatch
  | Invalid_range of string
  | Duplicate_rrule
  | Rrule_error of Recur.parse_error
  | Until_dtstart_mismatch of { dtstart_form : string; until_form : string }

val parse : Content_line.t list -> (t, parse_error) result
(** Project the recurrence identity from one VEVENT's content lines. Total. *)

val parse_error_to_string : parse_error -> string
