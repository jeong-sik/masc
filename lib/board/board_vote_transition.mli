(** Pure vote admission and counter changes shared by post and comment voting. *)

type t
(** One accepted first vote or direction flip. *)

type decision =
  | Already_cast
  | Cast of t

val decide :
  previous:Board_types.vote_direction option ->
  direction:Board_types.vote_direction ->
  decision
(** [None] means the voter has not voted on this target. The caller must
    decide again from the current vote after the durable append, rather than
    retaining a staged transition across that effect. *)

val apply_counts : t -> votes_up:int -> votes_down:int -> int * int
(** Returns the new [(votes_up, votes_down)], preserving the current floor of
    zero when removing the previous direction during a flip. *)
