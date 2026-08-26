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

val kind_label : kind -> string
(** What a reference points at, for a reader. The path segment is the wire
    form ("overview/tasks"); this is the word a screen prints. *)

val scan : string -> (kind * string) list
(** Every [masc://] reference in a body, in the order it appears, without
    repeats.

    Only references this program's own {!reference} could have written. A
    board post that happens to spell an id in prose is not linked to it: a
    link the writer did not make is a claim nobody checked, and the whole
    point of following one is that it goes where it says. *)

val osc52_copy : string -> string
(** [osc52_copy text] returns an OSC 52 clipboard-write sequence. *)
