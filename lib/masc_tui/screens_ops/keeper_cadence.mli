(** How often a keeper works and when its next schedule is due, read from the
    roster's turn pulse and the active schedules. Pure: the caller passes the
    wall clock. *)

type window = {
  turns : int;  (** Every turn that ended in the window, of any outcome. *)
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
  known_from : float option;
      (** [Some t] when the server knows turns only from [t], later than the
          window start, so the window is counted from [t]. *)
}

val window : now_unix:float -> hours:int -> Wire_fleet.turn_pulse -> window
(** The slots that start within the last [hours] hours of [now_unix]. *)

type next_due =
  | No_schedule  (** The keeper has no active schedule. *)
  | Due_in of float  (** Seconds until the earliest due schedule. *)
  | Late_by of float  (** Seconds since the earliest due time passed. *)
  | Due_unknown  (** Active schedules that name no due time. *)

val keeper_schedules : name:string -> Wire_work.schedule_row list -> Wire_work.schedule_row list
(** The schedules that wake [name]: its keeper or its target is [name]. *)

val next_due : now_unix:float -> Wire_work.schedule_row list -> next_due
(** The earliest due time among one keeper's schedules. *)
