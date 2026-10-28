(** Per-invocation cancellation and settlement for executor submissions. *)
val submit : Eio.Executor_pool.t -> weight:float -> name:string -> (unit -> 'a) -> 'a
(** Invoke user work at most once. Cancellation retires pending entry or
    signals and joins the entered worker before re-raising the caller's
    original cancellation. Joining is protected cleanup; uncooperative work
    can delay it. Exceptions propagate without inline fallback or replay.
    Pool choice, worker marking and IO/CPU weights belong to the caller.
    The caller's {!Pool_lane} at submission keys the wait, run and abandoned
    times it records in {!Pool_wait}; [name] names the work there and labels
    the job's run as an Eio trace span (RFC-0474 L4c). *)
