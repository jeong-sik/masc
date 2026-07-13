(** Exec_program is an opaque executable name.

    The generic execution boundary records what the caller requested. It does
    not maintain a product-specific executable catalog or attach policy meaning
    to program names. *)

type t
type unknown = [ `Unknown of string ]

val of_string : string -> (t, unknown) result
(** Preserve a non-empty executable exactly as supplied. Any backend-specific
    executable-path containment belongs at that backend boundary. *)

val to_string : t -> string
val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
val to_yojson : t -> [> `String of string ]
