(** Reduction of fleet schedule agenda into a Keeper's next run status (RFC-0511 A1). *)

type t =
  | No_schedule
  | Scheduled_at of float
  | Late_since of float
  | Held_current of float
  | Held_as_of of float
  | Not_before of float
  | Unknown

type index

val index_of_agenda :
  freshness:Masc_tui_agenda.schedule_freshness ->
  ?runner:Masc.Tui_decode.schedule_runner_status ->
  Masc_tui_types.schedule_snapshot option ->
  index

val of_snapshot :
  freshness:Masc_tui_agenda.schedule_freshness ->
  ?runner:Masc.Tui_decode.schedule_runner_status ->
  keeper_name:string ->
  Masc_tui_types.schedule_snapshot ->
  t

val find : index -> keeper_name:string -> t

val cell : now:float -> t -> Masc_tui_keeper_axis_cell.t option

(** {1 The strip ahead} (RFC-0515 V7)

    The status, cause and time views draw, after the NOW cell, a keeper's
    scheduled wakes over the next {!Masc_tui_keeper_mark.pulse_hours} clock
    hours. The hours are the pulse's hours ({!Masc_tui_keeper_pulse.hour_start})
    mirrored: the first is the hour that holds [now], and a wake before [now]
    is not in it.

    A row's wakes come from its recurrence and the time it is next due
    ({!Masc_tui_types.schedule_row_due_time}). An interval adds its period to
    that time; a daily or cron recurrence asks
    {!Schedule_domain.first_due_after}, the function the store reschedules
    with. A wake at or after the row's expiry is not counted. A held row is
    left out: {!cell} says it is held, and when it runs is the runner's call. *)

type hour =
  | Hour_quiet  (** Nothing wakes the keeper in this hour. *)
  | Hour_wakes of int  (** Exactly this many wakes, at least one. *)
  | Hour_wakes_at_least of int
      (** At least this many, at least one; the agenda does not show all of
          the hour. *)
  | Hour_unknown
      (** The agenda cannot say whether anything wakes the keeper in this
          hour. *)

val hours_of_snapshot :
  now:float -> keeper_name:string -> Masc_tui_types.schedule_snapshot option -> hour list option
(** [None] is a keeper with no schedule: no active row, and no row cut off the
    page. An agenda not read, or read with an error, is every hour unknown;
    so is a [now] that is not a clock reading.

    The agenda does not show an hour in full in three cases. A cut page
    leaves out rows due no earlier than its last active row, so from that
    time on every keeper's hours are partly unseen. A row whose due time does
    not read leaves all of its hours unseen. A row whose recurrence did not
    decode wakes at its due time, and what comes after is unseen. *)

val find_hours : index -> now:float -> keeper_name:string -> hour list option
(** {!hours_of_snapshot} of the index's agenda. The rows' wakes are kept for
    the clock hour of [now], so a cron is walked once an hour, not once a
    frame; the count against [now] is taken on every call. *)

val hour_mark : hour -> string
(** {!Masc_tui_keeper_mark.schedule_strip_wake_mark} for an hour with a wake,
    {!Masc_tui_keeper_mark.schedule_strip_quiet_mark} for a quiet one and
    {!Masc_tui_keeper_mark.unknown_mark} for an unknown one. *)

val hours_cell : hour list -> Masc_tui_keeper_axis_cell.t
(** One {!hour_mark} per hour, the hour that holds [now] first. *)
