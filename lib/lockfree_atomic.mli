(** Lock-free atomic update helpers built on [Atomic.compare_and_set].

    Consolidates the CAS-loop pattern that has been duplicated across
    lock-free registry refactors (agent_registry_eio, sse, tool_registry...).

    [update_with_result] exists to eliminate the [ref + Option.get] anti-pattern
    that appears when a caller needs both the new state and a value derived
    from the transformation.

    @since 0.11.x *)

(** [update atomic f] repeatedly runs [f] against the current value and
    commits the result via CAS, retrying on contention. *)
val update : 'a Atomic.t -> ('a -> 'a) -> unit

(** [update_with_result atomic f] is [update] but [f] returns both the new
    state and a derived value; the derived value of the committed attempt
    is returned.

    Important: [f] may be invoked multiple times under contention. It must
    be pure with respect to observable effects, or tolerate repeated calls. *)
val update_with_result : 'a Atomic.t -> ('a -> 'a * 'b) -> 'b
