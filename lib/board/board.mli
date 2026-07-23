(** Board — top-level public facade for the board store.

    The .ml is a single line: [include Board_votes].  This
    .mli mirrors the runtime with [include module type of
    struct include Board_votes end] so type identity is
    preserved end-to-end across the four-hop chain
    {!Board_types} → {!Board_core_classify} →
    {!Board_core_payload} (runtimed inside {!Board_core}) →
    {!Board_core} → {!Board_votes} → {!Board}.

    Callers reach the entire board surface — store /
    persistence / classification / payload normalisation /
    voting / karma / flair — through {!Board.X} unqualified
    after [open Masc].  478 dotted [Board.X] call sites
    in lib + bin + test all resolve through this runtime.

    No locally-defined surface; this facade has no
    behavioural code of its own.  Every entry visible from
    {!Board} traces back to one of the four upstream
    modules. *)

include module type of struct
  include Board_votes
end

val audience_for_post
  :  visibility:visibility
  -> title:string
  -> content:string
  -> (audience, board_error) result

val audience_for_comment : content:string -> (audience, board_error) result
val audience_for_reaction : audience
val audience_label : audience -> string
val direct_targets_of_text : string -> Agent_id.t list
