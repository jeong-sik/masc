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
      (** The server no longer holds this hour: it kept only a keeper's newest
          turns and dropped older ones, or it sent no pulse at all. *)
  | Slot_quiet
      (** The server holds this hour and no autonomous turn ran in it. The
          server counts autonomous turns only, so a chat turn leaves no mark. *)
  | Slot_turn of Masc.Keeper_turn_pulse.outcome
      (** The worst turn of the hour: failed over rested over ok. *)

val slots : now:float -> Masc.Keeper_turn_pulse.pulse option -> slot list
(** The last {!Masc_tui_keeper_mark.pulse_hours} hours before [now], oldest
    first. Hour [n] counts back from [now] in whole hours, so the newest hour
    is the one just ended, and a turn stamped after [now] (the two clocks
    disagree) belongs to it.

    An hour with no turn reads {!Slot_unknown} when the pulse is [truncated]
    and the hour is older than the oldest turn the server holds, and
    {!Slot_quiet} otherwise. A truncated pulse that holds a turn older than the
    whole window knows every hour of it. The oldest hour that holds a turn may
    have lost older turns to the same cut; it shows the worst of those that
    remain.

    [None] is a pulse the server did not seed: every hour is unknown. So is any
    pulse read against a [now] that is not a finite number. A turn whose time is
    not a finite number is left out. *)

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
