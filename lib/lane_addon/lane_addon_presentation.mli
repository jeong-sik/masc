(** Package-authored display metadata. Display never changes observation truth. *)
type format = Text | Number | Boolean | Json
type row_action = {
  lane_id : string;
  label : string;
  fixed : (string * Yojson.Safe.t) list;
  from_row : (string * string list) list;
}
(** A lane action the rows of [lane_id] offer. [fixed] members carry the
    package's values, [from_row] members are read from the row's fields at
    their path, and the operator fills the members left. The filled action goes
    through the same lane action validation and authority as any other, so a
    row action is a shorter way to write an action, not a new permission. An
    action is named by its position in [actions]; [label] is only what a screen
    shows. Declared before [reading] so an unannotated [lane_id] or [label]
    still means a reading's. *)
type reading = {
  lane_id : string;
  path : string list;
  label : string;
  unit : string option;
  format : format;
}
type t = { description : string option; readings : reading list; actions : row_action list }
val empty : t
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
(** Writes [actions] only when there is one, so a package without row actions
    keeps its declaration revision. *)
type row_value = Present of Yojson.Safe.t | Absent | Wrong_shape
val row_value : string list -> Yojson.Safe.t -> row_value
(** The value a row action member reads from a row's fields. [Absent]: a key
    on the path is missing. [Wrong_shape]: a step on the path is not an object,
    or the value is [null]. *)
val value : reading -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** The value [reading.path] addresses in a row's fields, once it matches the
    declared format. A text value keeps its line breaks; the terminal and HTML
    consumers lay the value out and sanitize/escape it at their own display
    boundary. *)
