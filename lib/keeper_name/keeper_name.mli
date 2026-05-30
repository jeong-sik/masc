(** Keeper name — simple provider:model string alias.

    Moved from [Keeper_name] to decouple from cascade module surface. *)

type t = string

val of_string : string -> (t, [ `Invalid_prefix | `Empty ]) result
(** Parse a raw keeper name. Rejects empty string; otherwise returns
    the trimmed input. The [`Invalid_prefix] error is retained in the
    variant for backward compatibility at call sites but is no longer
    emitted. *)

val of_string_exn : string -> t
(** Development-time convenience. Raises [Failure] on empty input. *)

val of_string_or : fallback:t -> string -> t
(** Parse a keeper name, returning [fallback] on invalid input instead
    of raising. *)

val to_string : t -> string
(** Extract the plain string. Identity for [t = string]. *)

val pp : Format.formatter -> t -> unit
