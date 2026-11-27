(** The environment an official client is spawned with, as ["NAME=value"]
    entries. *)

val set : (string * string) list -> string array -> string array
(** [set entries environment] is [environment] with each name of [entries]
    holding its value. An entry of [environment] with one of those names is
    dropped, so the child reads the value given here and never the one it
    would have inherited. *)
