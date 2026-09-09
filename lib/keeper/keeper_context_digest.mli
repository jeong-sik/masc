(** Content digests for the parts of a keeper turn's model input.

    One implementation, because the values are compared across stores: the
    [context_injected] runtime manifest and the diagnostic wire capture both
    name the same replayed history, and a row from one joins to a row from the
    other only while the two digests are computed the same way. Both producers
    sit on opposite sides of the [Keeper_run_tools] dependency chain, so the
    algorithm lives below both rather than in either. *)

val text : string -> string
(** MD5 hex of a rendered prompt block. *)

val message_texts_as_joined : Agent_core.Types.message list -> string
(** MD5 hex of the message texts joined by newline, in order. The empty list
    digests as the empty string, so a turn with no replayed history is not
    distinguishable from one whose messages all rendered empty — the message
    count recorded alongside it carries that distinction.

    Nonempty histories are computed on the shared CPU executor when called
    from an Eio fiber with a pool installed. The immutable message list is
    read in the worker and the caller awaits the digest before publishing it.
    Empty histories, calls already inside Executor_pool_ref.submit_or_inline
    workers, and callers without a pool or Eio context compute inline. The
    executor adapter may retry this pure computation inline on a
    non-cancellation executor error. Cancellation propagates to the caller. *)
