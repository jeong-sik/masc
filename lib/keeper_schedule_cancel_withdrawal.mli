(** Explicit composition adapter that removes the Keeper wakes a schedule
    already queued when the schedule is cancelled. It carries no
    process-global hook; callers pass this authority into
    [Tool_schedule.context], and [Schedule_store.cancel_request] calls it
    under the ledger lock. *)
val run
  :  Workspace.config
  -> Schedule_domain.schedule_request
  -> Schedule_domain.cancellation
  -> (unit, string) result
