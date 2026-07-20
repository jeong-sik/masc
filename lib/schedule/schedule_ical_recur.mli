(** Schedule_ical_recur — RFC 5545 §3.3.10 RECUR value type.

    Typed parser and canonical serializer for the iCalendar recurrence rule
    value (the value of the [RRULE] property). Pure: no I/O, no evaluation
    engine. This is the first leaf of the RFC 5545 adapter tracked by issue
    #24553; occurrence expansion, [RDATE]/[EXDATE], [DTSTART] consistency
    (e.g. UNTIL value-type agreement), and [VTIMEZONE]/[TZID] resolution are
    later leaves that build on this type.

    Exactness stance (no silent coercion, matching the repo's fail-closed
    policy):
    - Every grammar rule of §3.3.10 is enforced: unknown/duplicate parts,
      missing [FREQ], [UNTIL]+[COUNT] conflict, per-part numeric ranges, and
      the [FREQ]-dependent [BYxxx] restrictions are all typed parse errors.
    - Case-insensitivity follows the RFC: part names and enumerated values
      ([FREQ], weekdays) are case-insensitive; nothing else is normalized.
    - The parser is total: any input string yields a typed result, never an
      exception. *)

type freq = Secondly | Minutely | Hourly | Daily | Weekly | Monthly | Yearly

type weekday =
  | Sunday | Monday | Tuesday | Wednesday | Thursday | Friday | Saturday

(** A [BYDAY] element. [ordinal] is the signed nth-occurrence prefix
    ([[+/-]ordwk] in the grammar, range -53..-1 or 1..53); [None] means the
    bare weekday form. *)
type weekday_num = private { ordinal : int option; day : weekday }

(** Proleptic Gregorian calendar date, validated (month 1-12, day within the
    month including the leap-year rule). *)
type date = private { year : int; month : int; day : int }

(** Time of day. [second] admits 0-60 so a leap second is representable
    (§3.3.12 [time-second]). *)
type time_of_day = private { hour : int; minute : int; second : int }

(** The [UNTIL] bound in its three wire forms. Which form is legal depends on
    the companion [DTSTART] value type (§3.3.10); that cross-property check is
    the VEVENT layer's job, not this module's. *)
type until = private
  | Until_date of date
  | Until_local of date * time_of_day
  | Until_utc of date * time_of_day

(** Recurrence bound: [UNTIL] and [COUNT] are mutually exclusive (§3.3.10). *)
type bound = private
  | Forever
  | Count of int  (** >= 1 *)
  | Until of until

(** A validated RECUR value. All lists preserve wire order; an empty list
    means the part was absent (the RFC assigns no default to any [BYxxx]
    part). [interval] defaults to 1 and [wkst] to [Monday] per the RFC.

    The validation-sensitive types above and [t] itself are [private]:
    external code can read and pattern-match but cannot construct. The only
    producer is {!parse}, so every constructible [t] satisfies the documented
    invariants — and {!to_string} therefore never has to re-validate, which is
    what makes the [parse (to_string t) = Ok t] contract total. *)
type t = private
  { freq : freq
  ; bound : bound
  ; interval : int  (** >= 1 *)
  ; bysecond : int list  (** each 0-60 *)
  ; byminute : int list  (** each 0-59 *)
  ; byhour : int list  (** each 0-23 *)
  ; byday : weekday_num list
  ; bymonthday : int list  (** each -31..-1 or 1..31 *)
  ; byyearday : int list  (** each -366..-1 or 1..366 *)
  ; byweekno : int list  (** each -53..-1 or 1..53 *)
  ; bymonth : int list  (** each 1-12 *)
  ; bysetpos : int list  (** each -366..-1 or 1..366 *)
  ; wkst : weekday
  }

(** Closed sum of every rejection the parser can produce. Carries the
    offending part name or value so diagnostics are exact, not positional. *)
type parse_error =
  | Empty_part  (** A [;;] run or a leading/trailing [;]. *)
  | Missing_equals of string  (** A part with no [=] separator. *)
  | Unknown_part of string
  | Duplicate_part of string
  | Missing_freq
  | Invalid_freq of string
  | Invalid_number of { part : string; value : string }
  | Out_of_range of { part : string; value : int; min : int; max : int }
  | Invalid_date of string
  | Invalid_time of string
  | Invalid_until of string
  | Invalid_weekday of string
  | Until_count_conflict
  | Numeric_byday_not_allowed of freq
      (** Numeric [BYDAY] requires [FREQ=MONTHLY] or [FREQ=YEARLY]. *)
  | Numeric_byday_with_byweekno
      (** Numeric [BYDAY] with [FREQ=YEARLY] forbids [BYWEEKNO]. *)
  | Bymonthday_with_weekly  (** [BYMONTHDAY] forbids [FREQ=WEEKLY]. *)
  | Byyearday_not_allowed of freq
      (** [BYYEARDAY] forbids [FREQ=DAILY|WEEKLY|MONTHLY]. *)
  | Byweekno_not_allowed of freq  (** [BYWEEKNO] requires [FREQ=YEARLY]. *)
  | Bysetpos_without_byxxx  (** [BYSETPOS] requires another [BYxxx] part. *)

val parse : string -> (t, parse_error) result
(** Parse one RECUR value (the text after [RRULE:]). Total. *)

val to_string : t -> string
(** Canonical serialization: [FREQ] first (RFC-required for backward
    compatibility), then the bound, [INTERVAL], the [BYxxx] parts in grammar
    order, and [WKST] last. Round-trips: [parse (to_string t) = Ok t]. *)

val parse_error_to_string : parse_error -> string

val parse_date_value : string -> (date, parse_error) result
(** Parse and validate an RFC 5545 DATE value ([YYYYMMDD]). Exposed for
    property layers (DTSTART, RECURRENCE-ID, RDATE/EXDATE) that share the
    same value grammar. *)

val parse_time_of_day_value : string -> (time_of_day, parse_error) result
(** Parse and validate an RFC 5545 TIME value ([HHMMSS], leap second
    admitted). *)

val freq_to_string : freq -> string
val weekday_to_string : weekday -> string
