(** How often a keeper works and when its next schedule is due, read from the
    roster's turn pulse and the active schedules. Pure: the caller passes the
    wall clock. *)

open Masc_tui_protocol

type window = {
  turns : int;  (** Every turn in the window's slots, of any outcome. *)
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
  known_from : float option;
      (** [Some t] when the server knows turns only from [t], later than the
          window start, so the window is counted from [t]. *)
}

val window_hours : int list
(** The windows a keeper's work tab shows: 6 and 24 hours. *)

val window : now_unix:float -> hours:int -> Wire_fleet.turn_pulse -> window
(** The last [hours * 2] half-hour slots, the one holding [now_unix]
    included. *)

type next_due =
  | No_schedule  (** The keeper has no active schedule. *)
  | Due_in of float  (** Seconds until the earliest due schedule. *)
  | Late_by of float  (** Seconds since the earliest due time passed. *)
  | Due_unknown  (** Active schedules that name no due time. *)
  | Past_page_read
      (** No row read names the keeper, and the list has more pages, so its
          schedules may lie past the page read. *)

val keeper_schedules : name:string -> Wire_work.schedule_row list -> Wire_work.schedule_row list
(** The schedules that wake [name]: its keeper or its target is [name]. *)

val next_due : now_unix:float -> more_pages:bool -> Wire_work.schedule_row list -> next_due
(** The earliest due time among one keeper's schedules read. With
    [more_pages], an earlier one may lie on a page not read. *)

val block_rows : Wire_fleet.turn_pulse option -> int
(** The rows the work tab's cadence block draws: its hairline, two per window
    or one line saying the pulse is missing, and the next-due line. *)
