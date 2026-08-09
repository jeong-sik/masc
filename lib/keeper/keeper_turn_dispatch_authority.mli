(** Child-local authority for the final provider-dispatch validation.

    Keeper Owner owns scheduling and single-running admission. This token only
    binds the input/lifecycle validator selected by that admitted child to its
    provider calls. It has no per-Keeper mutex or persistent identity. *)

type token

val run : (token -> 'a) -> 'a
(** Create one token for [f] and invalidate it before returning or re-raising. *)

val install
  : token -> (unit -> (unit, string) result) -> (unit, string) result
(** Install the validator exactly once while the child is active. *)

val validate : token -> (unit, string) result
(** Reject an inactive/uninitialized token, otherwise run its validator. *)
