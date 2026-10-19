(** Which queue a request joins while its endpoint's permits are all held.

    A consumer marks the requests whose answer something else is waiting on
    as [Priority]; ordinary work is [Standard] and deferrable maintenance is
    [Background]. The class only matters
    for an endpoint that declares a priority run limit (see
    {!Slot_scheduler.create}); without one, all classes share one FIFO. *)
type t =
  | Priority
  | Standard
  | Background

val to_string : t -> string
