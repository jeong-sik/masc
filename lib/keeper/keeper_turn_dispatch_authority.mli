(** Child-local authority for the final provider-dispatch validation.

    Keeper Owner owns scheduling and single-running admission. This token only
    binds the input/lifecycle validator selected by that admitted child to its
    provider calls. It has no per-Keeper mutex or persistent identity. *)

type token

val run : (token -> 'a) -> 'a
(** Create one token for [f] and invalidate it before returning or re-raising.
    An invalidated token no longer retains its validator. A validation already
    executing may still hold that callback and return its result after closure;
    invalidation does not revoke that in-progress call. *)

val install
  : token -> (unit -> (unit, string) result) -> (unit, string) result
(** Install the validator exactly once while the child is active. *)

val validate : token -> (unit, string) result
(** Reject an inactive/uninitialized token, otherwise run its validator. *)
