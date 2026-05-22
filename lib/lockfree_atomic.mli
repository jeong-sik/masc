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

(** Record-labelled commit describing the next state and a derived value.
    Provided for call sites where positional tuples hurt readability. *)
type ('state, 'result) commit = {
  next_state : 'state;
  result : 'result;
}

(** [update_with_commit atomic f] is [update_with_result] but [f] returns
    a labelled [commit] record instead of a tuple. *)
val update_with_commit : 'a Atomic.t -> ('a -> ('a, 'b) commit) -> 'b
