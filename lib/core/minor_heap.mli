(** The minor heap size every domain of the process collects on. *)

val tune : unit -> unit
(** Give the calling domain the tuned minor heap, once.

    [Gc.set]'s [minor_heap_size] is per-domain in OCaml 5: it resizes the
    caller's minor heap and says nothing about domains that start later.
    The tuning in [main_eio.ml] therefore reached the main domain and no
    other, and the pool ran on the 2 MB default.

    That is not only a frequency: a minor collection is a stop-the-world
    barrier across every domain, so one domain collecting eight times as
    often stops the whole server that much more. Every pool job applies
    this on entry ({!Executor_pool_ref.with_worker_context}); a domain
    started outside a pool calls it itself.

    Idempotent, and a no-op on a domain already at or above the size. *)
