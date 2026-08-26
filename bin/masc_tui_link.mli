(** Stable references shared by the TUI surfaces. *)

type kind =
  | Board_post
  | Goal
  | Schedule
  | Task
  | Fusion_run
  | Keeper

val reference : kind -> string -> string
(** [reference kind id] returns a control-free [masc://] reference. The
    identifier is percent-encoded as one path segment. *)

val parse : string -> (kind * string) option
(** [parse reference] reads back what {!reference} wrote: the kind and the
    decoded identifier, or [None] when the text is not a [masc://] reference
    this build knows.

    The surfaces print these references beside the thing they name -- a
    verdict says which task it judged, a goal says its own id. Printing them
    without being able to read them back is what made an operator copy an id
    by eye and go looking for it: the screen knew where the answer was and
    could not go there. *)

val osc52_copy : string -> string
(** [osc52_copy text] returns an OSC 52 clipboard-write sequence. *)
