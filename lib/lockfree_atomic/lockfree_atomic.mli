(** Lock-free atomic update helpers built on [Atomic.compare_and_set].

    Consolidates the CAS-loop pattern shared by current lock-free state owners
    such as [Sse].

    @since 0.11.x *)

(** [update atomic f] repeatedly runs [f] against the current value and
    commits the result via CAS, retrying on contention. *)
val update : 'a Atomic.t -> ('a -> 'a) -> unit

(** Record-labelled commit describing the next state and a derived value. *)
type ('state, 'result) commit = {
  next_state : 'state;
  result : 'result;
}

(** [update_with_commit atomic f] repeatedly runs [f] against the current
    value, commits the returned [next_state] via CAS, retrying on contention,
    and returns the [result] of the commit that succeeded. *)
val update_with_commit : 'a Atomic.t -> ('a -> ('a, 'b) commit) -> 'b
