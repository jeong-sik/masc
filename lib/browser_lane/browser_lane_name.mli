(** The name a browser lane carries on every wire: the tool input [lane], the
    [source] of a surface, observation or screenshot, a lane addon's browser
    selection, and the TUI.

    Every reader decodes the name here and matches on [t], so a new lane is a
    non-exhaustive match at each reader instead of a string one of them
    forgets. What a reader then requires of the name (a live client id, for
    example) stays with that reader. *)

type t = Live | Automation

(** Every lane, in constructor order. *)
val all : t list

val to_wire : t -> string

(** [None] for any string that is not exactly a lane name. *)
val of_wire : string -> t option

(** ["live or automation"]: the names a reader accepts, for its error text. *)
val expected : string
