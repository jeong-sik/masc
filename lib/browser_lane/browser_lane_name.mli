(** The name a browser lane carries on every wire: the tool input [lane], the
    [source] of a surface, observation or screenshot, a lane addon's browser
    selection, and the TUI.

    Every reader decodes the name here, and a reader that branches on the lane
    matches on [t] without a catch-all, so a new lane is a non-exhaustive
    match at each of them instead of a string one of them forgets. What a
    reader then requires of the name (a live client id, for example) stays
    with that reader. *)

(** [all] (derived) lists every lane in constructor order. *)
type t = Live | Automation | Stagehand [@@deriving enumerate]

val to_wire : t -> string

(** [None] for any string that is not exactly a lane name. *)
val of_wire : string -> t option

(** ["live or automation or stagehand"]: every lane name, for the error text
    about a string that is no lane name. A reader that accepts only some lanes
    names those itself. *)
val expected : string
