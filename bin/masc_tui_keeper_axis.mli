(** Horizontal visual axis cells for Keeper secondary row (RFC-0511 A2). *)

val segments :
  Masc_tui_types.state ->
  now:float ->
  keeper_name:string ->
  runtime:Masc.Tui_decode.keeper_runtime option ->
  Masc_tui_keeper_axis_cell.t list
(** The cells of one keeper's second row, in the order they yield to a narrow
    row: the last one is dropped first. [runtime] is the keeper's row from the
    live roster, [None] when the roster did not read it; the failing-for and
    turn-pulse cells (RFC-0511 D1) come from it and the others from [state]. *)

val run_cell :
  Masc_tui_types.state -> now:float -> keeper_name:string -> Masc_tui_keeper_axis_cell.t option
(** The next scheduled run cell of {!segments}. *)

val wake_strip :
  Masc_tui_types.state ->
  now:float ->
  ahead:int ->
  keeper_name:string ->
  Masc_tui_keeper_next_run.wake_slot list
(** [keeper_name]'s wake strip ({!Masc_tui_keeper_next_run.wake_strip}) from
    the state's schedule agenda, through the same cached index as
    {!segments}, so a frame does not walk the recurrences again. While the
    last agenda read failed, every slot is unknown: the list on hand is
    older than the failure. *)

val memory_index : Masc_tui_types.state -> Masc_tui_keeper_memory_reading.index
(** The state's memory health as the index {!segments} reads, built once per
    snapshot. *)

(** {1 Readings for the Keepers views} (RFC-0515 §2.3)

    The bounds below are display values. They are not server state, and the
    age of a snapshot is its age, not a verdict on it (RFC-0418). *)

val due_of_next_run : now:float -> Masc_tui_keeper_next_run.t -> Masc_tui_keeper_list_model.due
(** A scheduled time an hour or less ahead, or already passed without the run
    being due, is within the hour. A lower bound from a cut agenda says
    "later" only when it lies beyond twelve hours; nearer, the real time is
    unknown. *)

val follow_of_memory : Masc_tui_keeper_memory_reading.t -> Masc_tui_keeper_list_model.memory_follow
(** A stalled gap, measured or not, comes before lag. A row whose lag was not
    measured is unread. *)

val age_of_memory : now:float -> Masc_tui_keeper_memory_reading.t -> Masc_tui_keeper_list_model.memory_age
(** The age of the snapshot's last update; an update stamped ahead of [now]
    is within three hours. *)

val outside :
  Masc_tui_types.state -> now:float -> keeper_name:string -> Masc_tui_keeper_list_model.outside
(** [keeper_name]'s readings from the state's schedule agenda and memory
    health, through the same cached indexes as {!segments}. *)

val next_run : Masc_tui_types.state -> keeper_name:string -> Masc_tui_keeper_next_run.t
(** [keeper_name]'s next run from the state's schedule agenda, through the
    same cached index as {!segments}. The views' due column draws it. *)
