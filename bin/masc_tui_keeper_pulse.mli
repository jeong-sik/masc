(** The failing-for cell of the Keepers second row (RFC-0511 D1).

    It draws a value the server wrote on the keeper's roster row. It reads no
    clock of its own: the caller passes [now], so one frame shares one instant
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
