(** The failing-for cell and the turn-pulse cell of the Keepers second row
    (RFC-0511 D1).

    Both draw values the server wrote on the keeper's roster row. Neither reads
    a clock of its own: the caller passes [now], so one frame shares one instant
    and a test can state it. *)

(** How long the keeper's failing phase has lasted, as far as the row knows. *)
type failing =
  | Not_failing
  | Failing_since of float  (** The phase began at this Unix time. *)
  | Failing_unrecorded
      (** The keeper is failing and the server recorded no start for the phase.
          The server sets the start when the phase begins, and a new registry
          entry starts with none. *)

val failing_of_health :
  health:Masc.Tui_decode.keeper_health_reading -> failing_since:float option -> failing
(** The roster sends [failing_since] as [None] both for a healthy keeper and
    for a failing one whose start was not recorded, so the value alone cannot
    say which. The health reading does: only [Health_failing] is a failing
    keeper. A start on a keeper whose health reads otherwise is not drawn; the
    health column is what says whether the keeper is failing. *)

val failing_cell : now:float -> failing -> Masc_tui_keeper_axis_cell.t option
(** The word {!Masc_tui_keeper_mark.failing_since_word} and how long the phase
    has lasted, in the span the rest of the screen uses. A start that is ahead
    of [now], or too far off to be a span, reads as
    {!Masc_tui_keeper_mark.unknown_mark}. Always {!Masc_tui_keeper_axis_cell.Failure};
    [None] for a keeper that is not failing. *)

(** What the server says about one hour of the pulse window. *)
type slot =
  | Slot_unknown
      (** No turn is counted in this hour and the hour starts before the
          server's [known_since], so turns may have ended in it unseen; or the
          server sent no pulse at all. *)
  | Slot_quiet
      (** The server holds this hour and no autonomous turn ran in it. The
          server counts autonomous turns only, so a chat turn leaves no mark. *)
  | Slot_turn of Masc.Keeper_turn_pulse.outcome
      (** The worst turn of the hour: failed over rested over ok. *)

val slots : now:float -> Masc.Keeper_turn_pulse.pulse option -> slot list
(** The last {!Masc_tui_keeper_mark.pulse_hours} clock hours, oldest first.
    The newest is the hour that holds [now], and a slot stamped after that hour
    (the two clocks disagree) belongs to it. An hour joins the server's two
    half-hour slots in it.

    An hour with no counted turn reads {!Slot_unknown} when it starts before
    the pulse's [known_since], and {!Slot_quiet} otherwise.

    [None] is a pulse the server did not send: every hour is unknown. So is any
    pulse read against a [now] that is not a finite number. *)

val slot_mark : slot -> string
(** The mark one hour draws. The marks of the five readings differ, so an hour
    the server no longer holds never looks like one that rested or one in which
    no turn ran. *)

val pulse_cell :
  now:float -> Masc.Keeper_turn_pulse.pulse option -> Masc_tui_keeper_axis_cell.t option
(** One {!slot_mark} per hour, oldest first, so the newest hour is at the right
    edge. {!Masc_tui_keeper_axis_cell.Attention} when any hour holds a failed
    turn, {!Masc_tui_keeper_axis_cell.Quiet} otherwise. [None] when the server
    holds every hour of the window and none holds a turn: there is nothing to
    draw, which is not the same as not knowing. *)

(** What the server says about one half hour of the views' pulse column
    (RFC-0515 §2.4.3). A rested turn counts as a failed one, as the decision
    log writes it. *)
type half_hour =
  | Half_hour_unknown
      (** No turn is counted in it and it starts before the server's
          [known_since], so turns may have ended in it unseen; or the server
          sent no pulse at all. *)
  | Half_hour_quiet  (** The server holds it and no autonomous turn ended in it. *)
  | Half_hour_ok  (** Turns ended in it and none failed or rested. *)
  | Half_hour_failed  (** A turn failed or rested in it and none finished ok. *)
  | Half_hour_failed_and_ok
      (** A turn failed or rested in it and another finished ok. The server
          counts each outcome without their order. *)

val half_hours :
  now:float -> count:int -> Masc.Keeper_turn_pulse.pulse option -> half_hour list
(** The last [count] half hours, oldest first, one per server slot. The newest
    is the slot that holds [now], and a slot stamped after it (the two clocks
    disagree) belongs to it. A count of 0 or less is no half hour.

    [None] is a pulse the server did not send: every half hour is unknown. So
    is any pulse read against a [now] that is not a finite number. *)

val half_hour_mark : half_hour -> string
(** The mark one half hour draws: [·] quiet, [▁] ok, [█] failed, [▄] failed
    and ok, {!Masc_tui_keeper_mark.unknown_mark} unknown. *)

