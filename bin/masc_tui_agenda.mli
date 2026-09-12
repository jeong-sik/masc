(** What is coming next, and what is waiting on the operator.

    Both facts were already on the screen somewhere, and neither was where the
    question gets asked. The next scheduled wake is computed by the server,
    decoded into [scs_next_due_iso], carried into the state -- and drawn only
    inside the Schedules surface, which you have to leave the chat to reach.
    This workspace answers it today by paying a keeper turn every 45 minutes
    to read the list out loud (schedule ["edgar-45min-check"], cron
    ["45 8-23 * * *"], "다음 일정과 해야 할 일을 알림으로 전달하시오").

    The strip is one row above the composer, and it is not drawn at all when
    there is nothing to say -- the rule the surface strip's Approvals badge
    already follows, where an always-on badge would be texture rather than
    information.

    {!rows_taken} is how that decision reaches both the frame and the keypress
    bound. A row the drawing adds while the bound counts rows without it is
    what put the Changes list out of reach of its own arrow keys, and the two
    read the same number here so it cannot happen again. *)

(** Whether a schedule is still ahead of the operator.

    The wire says status as a string. It is parsed here into the only question
    the strip asks, so a status nobody recognised stays off the strip instead
    of being defaulted onto it -- an unknown row is not a due row. *)
type standing =
  | Coming
  | Settled
  | Unrecognised of string

val standing_of_wire : string -> standing

type scheduled =
  { at_iso : string
        (** RFC 3339, as the wire sends it. The time is a field of the
            scheduled row rather than an option beside it: a row on the clock
            half of the strip has a clock. *)
  ; standing : standing
  ; who : string  (** [payload_target], e.g. ["keeper:edgar.a.poe"] *)
  ; what : string  (** [payload_summary], the title the operator wrote *)
  ; recurrence : string
        (** [recurrence_summary], e.g. ["every 3600s"]. The strip has no room
            for it; the overlay does, and it is the difference between "this
            happens every hour" and "this happens once". *)
  }

type awaiting =
  { asked_by : string
  ; question : string
  ; asked_at : float
  ; timeout_sec : float
        (** A held call is denied when the wait runs out, so the overlay says
            how long is left. Fields rather than an option: every held call
            the registry reports carries both. *)
  }
(** A keeper blocked until the operator answers. No time on purpose: the
    answer is due now, and a countdown would read as permission to wait. *)

type t

val project : scheduled:scheduled list -> awaiting:awaiting list -> t
(** Keeps the earliest {!Coming} row and counts the rest. Rows that are
    settled or unrecognised are not on the strip. *)

val rows_taken : t -> int
(** [1] while the strip has something to say, [0] otherwise. The surface gets
    the row back when it is [0]. *)

(** The strip's two halves, as plain text. Styling belongs to the renderer;
    what goes in each half belongs here. *)
type strip =
  { clock : string  (** the next wake, or [""] when nothing is scheduled *)
  ; waiting : string  (** the badge, or [""] when nobody is blocked *)
  }

val strip :
  now:float -> localtime:(float -> Unix.tm) -> cols:int -> t -> strip option
(** [None] exactly when {!rows_taken} is [0].

    A wake that falls on a later day says so. Rendering tomorrow's 08:00 as a
    bare ["08:00"] at 23:50 reads as eight minutes away. *)

(** {1 The overlay}

    The strip answers "is there anything"; this answers "what". They differ on
    the empty case: the strip draws nothing, because an always-on row saying
    nothing is happening is texture. The overlay says so in words, because the
    operator pressed a key to ask and a blank panel would read as a failure to
    load. *)

type tone =
  | Heading
  | Wake
  | Question
  | Quiet

type line =
  { tone : tone
  ; text : string
  }

val overlay :
  now:float -> localtime:(float -> Unix.tm) -> cols:int -> t -> line list
(** Every wake still coming, earliest first, then everyone blocked on the
    operator. Not just the one the strip names. *)

val short_who : string -> string
(** A wake target with its kind prefix removed: ["keeper:edgar.a.poe"] reads
    back as ["edgar.a.poe"].

    Every row a wake surface draws has the same kind, so the prefix
    distinguishes nothing and costs seven cells of a line that has to fit a
    name. That is not only waste: on a narrow column the seven cells are
    taken out of the name, and the name is the whole reason the cell exists.
    Two schedules for two different keepers both drew ["keeper:~"] before the
    Schedules list called this.

    Exported because a second surface needs the same answer, and two
    surfaces spelling the same rule twice is how they come to disagree. *)
