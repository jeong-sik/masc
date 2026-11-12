(** Settles a wait whose run left neither a worker nor a receipt. The startup
    recovery writes an [unfinished] receipt for a run that never recorded its
    end, but it writes none when the active request list cannot be read, and a
    receipt write can fail. A conversation that waits for such a run would wait
    forever. *)

val settle_lost : base_path:string -> keeper_name:string -> (unit, string) result
(** For every pending request of this Keeper that has ended or been cut off
    and has no receipt in the outbox: writes one [unfinished] receipt, then
    resolves the wait with {!Keeper_semantic_execution.Source_lost}. A request
    a worker may still own is left alone. The state decides, never a time
    limit. Every request is tried even when one fails; the error lists the
    failures.

    The receipt echoes the arguments the request record kept. A request with
    no record, or whose record is not a background Execute run's, has none to
    echo: its receipt carries [Unknown] arguments and says so in its message. *)

val after_wait : base_path:string -> keeper_name:string -> (unit, string) result
(** Run once a wait is recorded: the receipt, or the end of the run, may have
    come while the turn was ending, before the wait could see it. Resolves an
    arrived receipt ({!Keeper_receipt_wait_resolution.arrived}) and then
    {!settle_lost}. *)
