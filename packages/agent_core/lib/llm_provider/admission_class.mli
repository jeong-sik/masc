(** Which queue a request joins while its endpoint's permits are all held.

    A consumer marks the requests whose answer something else is waiting on
    as [Priority]; every other request is [Standard]. The class only matters
    for an endpoint that declares a priority run limit (see
    {!Slot_scheduler.create}); without one, both classes share one FIFO. *)
type t =
  | Priority
  | Standard

val to_string : t -> string
