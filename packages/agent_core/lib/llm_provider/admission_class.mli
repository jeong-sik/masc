(** Which queue a request joins while its endpoint's permits are all held.

    A consumer marks the requests whose answer something else is waiting on
    as [Priority]; ordinary work is [Standard] and deferrable maintenance is
    [Background]. Requests always queue in [Priority > Standard > Background]
    order; when an endpoint also declares [admission_priority_run_limit] (see
    {!Slot_scheduler.create}), waiting lower classes receive bounded service
    while higher classes keep arriving. *)
type t =
  | Priority
  | Standard
  | Background

val to_string : t -> string
