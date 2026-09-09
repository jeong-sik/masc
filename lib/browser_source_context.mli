(** Page-provided source hints. A decoded location is not authorization to read
    or write a local file. Resolve within the user's chosen checkout and verify
    its SHA-256 before editing. HTM points to a template, JSX to an element. *)
type kind = Template | Element
type location = { file : string; line : int; column : int; kind : kind; digest : string }
type t = Unmapped | Located of location | Invalid of string
val of_json : Yojson.Safe.t -> t
val label : t -> string
