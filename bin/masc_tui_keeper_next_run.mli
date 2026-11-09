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

(** {1 Wake strip (RFC-0515 §2.4.4)} *)

type wake_slot =
  | Wakes of int  (** Wakes known to fall in the slot. [Wakes 0] is known empty. *)
  | Wakes_unknown  (** No known wake, and the slot may hold one this build cannot list. *)

val wake_strip :
  index -> now:float -> ahead:int -> keeper_name:string -> wake_slot list
(** The half-hour slot that holds [now], then [ahead] slots after it, on the
    same 1800-second boundaries as the pulse. [ahead] below 0 gives no slot.

    The wakes are the Keeper's schedule rows walked through their recurrence:
    the first is {!Masc_tui_types.schedule_row_due_time}, an [Interval] adds
    its period, and [Daily] and [Cron] repeat
    [Schedule_domain.first_due_after]. A wake at or after the row's expiry is
    not counted. A wake that came due and is not yet late counts in the first
    slot. A late row or one the runner holds adds nothing.

    [Wakes_unknown] fills every slot when the agenda is missing or its read
    failed, the slots after the first wake of a row whose recurrence did not
    decode, and, on a cut agenda, the slots from the last row's due time on.

    A strip is remembered per Keeper and [ahead] until the now slot changes
    or the index is rebuilt. *)

val sum_wake_strips : wake_slot list list -> wake_slot list
(** Slot by slot: the known wakes added up, or [Wakes_unknown] when that sum
    is 0 and some strip did not know the slot. A strip shorter than another
    adds nothing to the slots it does not have. *)

val cell : now:float -> t -> Masc_tui_keeper_axis_cell.t option
