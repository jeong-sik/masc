(** A validated, exact lexical child name below a pinned directory
    capability. Values cannot contain path traversal or alternate component
    spellings, so they are safe mutation-lease keys. *)

type t

val is_valid : string -> bool
val of_string : string -> t option
val to_string : t -> string
val equal : t -> t -> bool
