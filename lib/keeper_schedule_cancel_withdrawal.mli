(** Explicit composition adapter that removes the Keeper wakes a schedule
    already queued when the schedule is cancelled. It carries no
    process-global hook; callers pass this authority into
    [Tool_schedule.context], and [Schedule_store.cancel_request] calls it
    under the ledger lock. Discovery and authoritative queue reads cover all
    durable owners and every instance of the public schedule id, independently
    of the current payload target. An unfinished matching transfer refuses
    cancellation until canonical recovery converges it. Errors can follow
    durable withdrawals; no rollback of those effects is promised. *)
val run
  :  Workspace.config
  -> Schedule_domain.schedule_request
  -> Schedule_domain.cancellation
  -> (unit, string) result
