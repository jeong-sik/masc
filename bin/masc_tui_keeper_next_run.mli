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
  | Wakes_with_unknown of int
      (** Known wakes in the slot, beside a range this build cannot list. The
          unknown stays explicit next to the positive count; adding slots
          never absorbs it. *)
  | Wakes_unknown  (** No known wake, and the slot may hold one this build cannot list. *)

val wake_strip :
  index -> now:float -> ahead:int -> keeper_name:string -> wake_slot list
(** The half-hour slot that holds [now], then [ahead] slots after it, on the
    same 1800-second boundaries as the pulse. [ahead] below 0 gives no slot.

    The wakes are the Keeper's schedule rows walked through their recurrence:
    the first is the request's next due ([sch_next_due_at_iso], else
    [sch_due_at_iso]), an [Interval] steps with
    [Schedule_domain.next_periodic_due_after], and [Daily] and [Cron] repeat
    [Schedule_domain.first_due_after]. A wake at or after the row's expiry is
    not counted. Every occurrence inside the now slot counts in it, whether
    it lies before or after [now], so the strip is the same for every [now]
    in one slot. A first due before the now slot that is not yet late counts
    once in the now slot, and the occurrences between it and the slot start
    are not counted: the runner fires a missed due once.

    [Wakes_unknown] fills every slot when the agenda is missing or its read
    failed, the slots after the first wake of a row whose recurrence did not
    decode, and, on a cut agenda, the slots from the last row's due time on.
    A late row, a held row and a row whose status word does not decode wake
    again at a time they do not say, so each is unknown up to its expiry.

    The rows add up as in {!sum_wake_strips}. A slot where one row knows a
    wake therefore shows that count even when another row there is unknown:
    RFC-0515 §2.4.4 counts only the known wakes once the sum is 1 or more,
    the rule the group rows (§2.4.7) and the header strip (§2.8) draw.

    A strip is remembered per Keeper and [ahead] until the now slot changes
    or the index is rebuilt. *)

val unknown_strip : ahead:int -> wake_slot list
(** A strip of {!wake_strip}'s length with every slot [Wakes_unknown]. *)

val sum_wake_strips : wake_slot list list -> wake_slot list
(** Slot by slot: the known wakes added up, or [Wakes_unknown] when that sum
    is 0 and some strip did not know the slot. It adds strips built for one
    window, which all have the same length. *)

val cell : now:float -> t -> Masc_tui_keeper_axis_cell.t option
