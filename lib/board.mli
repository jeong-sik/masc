(** Board — top-level public facade for the board store.

    The .ml is a single line: [include Board_votes].  This
    .mli mirrors the cascade with [include module type of
    struct include Board_votes end] so type identity is
    preserved end-to-end across the four-hop chain
    {!Board_types} → {!Board_core_classify} →
    {!Board_core_payload} (cascaded inside {!Board_core}) →
    {!Board_core} → {!Board_votes} → {!Board}.

    Callers reach the entire board surface — store /
    persistence / classification / payload normalisation /
    voting / karma / flair — through {!Board.X} unqualified
    after [open Masc_mcp].  478 dotted [Board.X] call sites
    in lib + bin + test all resolve through this cascade.

    No locally-defined surface; this facade has no
    behavioural code of its own.  Every entry visible from
    {!Board} traces back to one of the four upstream
    modules. *)

include module type of struct
  include Board_votes
end
