(** Board — top-level public facade for the board store.

    The runtime is two [include]s, and this .mli mirrors both
    with [include module type of] so type identity is
    preserved end to end.

    - {!Board_votes} carries the store / persistence /
      classification / payload / voting / karma / flair
      surface, itself layered as
      {!Board_types} → {!Board_core_classify} →
      {!Board_core_payload} (runtimed inside {!Board_core}) →
      {!Board_core} → {!Board_votes}.
    - {!Board_audience} carries the audience and mention
      resolution surface.  Both reach {!Board_types}; OCaml
      resolves the repeated definitions to the same types, so
      including both is not a conflict.

    Callers reach the whole surface through {!Board.X}
    unqualified after [open Masc].

    No behavioural code of its own: every entry visible from
    {!Board} is defined in {!Board_votes} or
    {!Board_audience}, and both are re-exported whole rather
    than by a hand-listed subset that could fall behind. *)

include module type of struct
  include Board_votes
end

include module type of struct
  include Board_audience
end
