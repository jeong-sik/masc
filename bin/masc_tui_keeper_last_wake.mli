(** The newest wake among one Keeper's schedules (RFC-0515 section 2.5).

    Every schedule row carries the newest wake of its own instance
    ([sch_last_wake_*]). The Keeper's last wake is the latest of those, whether
    or not the schedule that recorded it is still live. *)

type t =
  { row : Masc_tui_types.schedule_row  (** The schedule that woke the Keeper. *)
  ; at : float  (** When that wake started, in Unix seconds. *)
  }

val newest : Masc_tui_types.schedule_row list -> t option
(** The row whose [sch_last_wake_started_at_iso] is the latest instant. A row
    without a wake is not a candidate, and neither is a wake whose time is not
    RFC 3339: it cannot be placed among the others. On equal instants the row
    that comes first in the list wins. [None] when no row qualifies. *)
