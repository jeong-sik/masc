(** Pure response interpretation, separated from the UI domain's HTTP/cache
    and dataset admission work. Inputs must be immutable and [decode] must not
    read or change UI state, credentials or request ownership. *)

val run : name:string -> (unit -> 'a) -> 'a
(** Use the installed shared CPU pool from an Eio caller. Existing absent-pool,
    non-Eio and already-worker inline policies remain in force. Values and
    exceptions retain their original meaning; work is never retried here.
    Cancellation retains the pool's existing policy: already entered pure
    CPU work may finish after its caller stops waiting. Its result cannot
    perform cache publication or dataset admission on the worker.

    [name] labels the caller's existing Eio runtime-event scope around pool
    admission, decoding and return scheduling. It does not record a pure CPU
    duration, a painted frame measurement or a success verdict. No UI-owned
    frame timing state is changed from a worker or raw domain. *)
