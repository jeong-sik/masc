(** A Goal's due date, read once from the string the store keeps.

    [Goal_store.goal.due_date] is a string. Whoever needs a moment or a day
    out of it reads it here, so the upsert check and the Candle appraisal
    agree on what a due date is.

    A due date is [YYYY-MM-DD] and nothing else: four digits, a dash, two
    digits, a dash, two digits, and a day that exists in the calendar. It is
    not trimmed and it carries no zone. It falls due at 23:59:59 UTC of that
    day, whatever the operator's own time zone is.

    Pure: no function here reads a clock. *)

type t =
  | No_due_date
  | Due_date of
      { date : Ptime.date  (** The day, as written: year, month, day. *)
      ; instant : Ptime.t  (** 23:59:59 UTC of [date]. *)
      }
  | Unreadable_due_date of string
      (** A value that is not a due date, kept as it was written. *)

val read : string option -> t
(** [None] is {!No_due_date}. [Some raw] is a {!Due_date} when [raw] is exactly
    [YYYY-MM-DD] for a real calendar day and {!Unreadable_due_date} otherwise:
    [2026-9-3], [2026-13-01], [2026-02-30], [TBD], an empty string and a date
    with a space around it are all unreadable. *)
