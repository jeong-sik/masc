(** The minor heap size every domain of the process collects on. *)

val tune : unit -> unit
(** Apply the shared default minor-heap policy on the calling domain.

    If [OCAMLRUNPARAM] is present, the runtime's operator configuration stays
    authoritative and this changes nothing. Main and pool domains use the
    same rule. Otherwise raise only a smaller minor heap to the shared tuned
    size, preserving the other GC controls.

    [Gc.set]'s [minor_heap_size] is per-domain in OCaml 5: it resizes the
    caller's minor heap and says nothing about domains that start later.
    Every pool job applies this on entry
    ({!Executor_pool_ref.with_worker_context}); a domain
    started outside a pool calls it itself.

    Idempotent, and a no-op on a domain already at or above the size. *)
