(** A keeper's name as the ledger keys it.

    Same canonical form as [Keeper_identity.Keeper_id]: trimmed, lowercased
    ASCII, never blank. This library sits below the one that owns that type, so
    the rule is spelled again here. A name that is already canonical passes
    through both unchanged. *)

type t = private string

val of_string : string -> t option
(** [None] iff the input is whitespace-only. *)

val to_string : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int
val to_yojson : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Refuses a name that is not already canonical instead of quietly fixing it. *)
