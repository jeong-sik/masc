(** Per-invocation cancellation and settlement for executor submissions. *)
val submit : Eio.Executor_pool.t -> weight:float -> (unit -> 'a) -> 'a
(** Invoke user work at most once. Cancellation retires pending entry or
    signals and joins the entered worker before re-raising the caller's
    original cancellation. Joining is protected cleanup; uncooperative work
    can delay it. Exceptions propagate without inline fallback or replay.
    Pool choice, worker marking and IO/CPU weights belong to the caller.
    The caller's {!Pool_lane} at submission keys the wait and run times it
    records in {!Pool_wait}. *)
